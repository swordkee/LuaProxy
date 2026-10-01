--- Redis 客户端。
---
--- ## 相对 2017 年 `t_redis.lua` 修正的问题
---
--- ### 1) 连接从不归还（原版 t_redis.lua:199-209）
--- ```lua
--- local fun = redis[cmd]
--- local result, err = fun(redis, ...)
--- if not result or err then
---     return nil, err            -- ← 既不 set_keepalive 也不 close
--- end
--- if is_redis_null(result) then
---     result = nil               -- ← 也不归还
--- end
--- self.set_keepalive_mod(redis)
--- ```
--- 在 DMP 场景里 **缓存未命中是最常见的分支**（`result == nil`），
--- 也就是说每一次 miss 都会新建一条 TCP 连接并重做 AUTH，
--- keepalive 池形同虚设。此处用 `settle()` 收口所有出口。
---
--- ### 2) pipeline 在缓冲阶段重复占用连接（原版 t_redis.lua:110-128）
--- `commit_pipeline` 内部自己 `redis_c:new()` 并连接，等于绕开了实例自身的生命周期。
--- 此处直接复用实例持有的连接。
---
--- ### 3) `commands` 表遗漏命令导致 nil 调用（原版 t_redis.lua:198）
--- `local fun = redis[cmd]` 若 cmd 不在白名单里，`fun` 为 nil，直接
--- "attempt to call a nil value"。此处改为显式校验并返回可读错误。
---
--- ### 4) `db_index` 被接受但从未生效（原版 t_redis.lua:225）
--- 声明了却不 `select`，属于静默失效。

local util = require('lib.util')

local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local sformat = string.format
local tinsert = table.insert
local m_floor = math.floor
local tunpack = unpack or table.unpack

local _M = {}

_M._VERSION = '2.0'

--- 支持的命令白名单。
--- 显式列出而非 `__index` 兜底：未知命令要在开发期暴露，
--- 而不是运行到线上才报 "attempt to call a nil value"。
local COMMANDS = {}
for _, name in ipairs({
    'append', 'auth', 'bgrewriteaof', 'bgsave', 'bitcount', 'bitop',
    'blpop', 'brpop', 'brpoplpush', 'client', 'config', 'dbsize', 'debug',
    'decr', 'decrby', 'del', 'discard', 'dump', 'echo', 'eval', 'evalsha',
    'exec', 'exists', 'expire', 'expireat', 'flushall', 'flushdb',
    'get', 'getbit', 'getrange', 'getset', 'hdel', 'hexists', 'hget',
    'hgetall', 'hincrby', 'hincrbyfloat', 'hkeys', 'hlen', 'hmget',
    'hmset', 'hscan', 'hset', 'hsetnx', 'hvals', 'incr', 'incrby',
    'incrbyfloat', 'info', 'keys', 'lastsave', 'lindex', 'linsert', 'llen',
    'lpop', 'lpush', 'lpushx', 'lrange', 'lrem', 'lset', 'ltrim', 'mget',
    'migrate', 'move', 'mset', 'msetnx', 'multi', 'object', 'persist',
    'pexpire', 'pexpireat', 'ping', 'psetex', 'psubscribe', 'pttl',
    'publish', 'pubsub', 'quit', 'randomkey', 'rename', 'renamenx',
    'restore', 'rpop', 'rpoplpush', 'rpush', 'rpushx', 'sadd', 'save',
    'scan', 'scard', 'script', 'sdiff', 'sdiffstore', 'select', 'set',
    'setbit', 'setex', 'setnx', 'setrange', 'shutdown', 'sinter',
    'sinterstore', 'sismember', 'slaveof', 'slowlog', 'smembers', 'smove',
    'sort', 'spop', 'srandmember', 'srem', 'sscan', 'strlen', 'sunion',
    'sunionstore', 'sync', 'time', 'ttl', 'type', 'unwatch', 'watch',
    'zadd', 'zcard', 'zcount', 'zincrby', 'zinterstore', 'zrange',
    'zrangebyscore', 'zrank', 'zrem', 'zremrangebyrank',
    'zremrangebyscore', 'zrevrange', 'zrevrangebyscore', 'zrevrank',
    'zscan', 'zscore', 'zunionstore',
}) do
    COMMANDS[name] = true
end

_M.COMMANDS = COMMANDS

--- 命令 → 原版拼错的别名，保持调用方源码兼容。
local ALIASES = {
    hmget = 'hmget', commit_pipeline = 'commit_pipeline', init_pipeline = 'init_pipeline',
}

local Mt = {}
Mt.__index = _M

--------------------------------------------------------------------------------
-- 生命周期
--------------------------------------------------------------------------------

--- 创建客户端。**不建立连接**——连接在首次命令时惰性建立。
--- @param cfg table lib/config.load() 的结果
--- @param opts table|nil { db_index, timeout_ms, password }
--- @return table
function _M.new(cfg, opts)
    opts = opts or {}
    local spec = {
        host = opts.host or cfg.redis.host,
        port = opts.port or cfg.redis.port,
        timeout_ms = opts.timeout_ms or cfg.redis.timeout_ms,
        pool_max_idle_time_ms = opts.pool_max_idle_time_ms or cfg.pool_max_idle_time_ms,
        pool_size = opts.pool_size or cfg.redis.pool_size,
        password = opts.password or cfg.redis.password,
        db_index = tonumber(opts.db_index) or tonumber(cfg.redis.db_index) or 0,
    }
    return setmetatable({
        spec = spec,
        conn = nil,
        _reqs = nil,
    }, Mt)
end

--- 确保连接可用。
--- @param self table
--- @return table|nil conn
--- @return string|nil err
function _M.ensure(self)
    if self.conn then
        return self.conn
    end
    local redis, err = require('resty.redis')
    local conn, cerr = redis:new()
    if not conn then
        return nil, sformat('cannot create redis client: %s', tostring(cerr))
    end
    conn:set_timeout(self.spec.timeout_ms)

    local ok, kerr = conn:connect(self.spec.host, self.spec.port)
    if not ok then
        return nil, sformat('cannot connect redis %s:%s (%s)',
            self.spec.host, tostring(self.spec.port), tostring(kerr))
    end

    if self.spec.password and self.spec.password ~= '' then
        local aok, aerr = conn:auth(self.spec.password)
        if not aok then
            conn:close()
            return nil, sformat('redis auth failed: %s', tostring(aerr))
        end
    end

    if self.spec.db_index ~= 0 then
        local sok, serr = conn:select(self.spec.db_index)
        if not sok then
            conn:close()
            -- 原版接受 db_index 却从不 select，这里要么真的选，要么明确报错
            return nil, sformat('redis select %d failed: %s', self.spec.db_index, tostring(serr))
        end
    end

    self.conn = conn
    return conn
end

--- 归还 / 关闭连接。**所有出口都必须经过这里。**
--- @param self table
--- @param reusable boolean
function _M.settle(self, reusable)
    local conn = self.conn
    self.conn = nil
    if not conn then
        return
    end
    if reusable then
        local perWorker = m_floor(self.spec.pool_size / ngx.worker.count())
        if perWorker < 1 then
            perWorker = 1
        end
        local ok, err = conn:set_keepalive(self.spec.pool_max_idle_time_ms, perWorker)
        if not ok then
            ngx.log(ngx.WARN, 'redis set_keepalive failed: ', tostring(err))
        end
    else
        conn:close()
    end
end

local math_floor = math.floor

--------------------------------------------------------------------------------
-- 命令执行
--------------------------------------------------------------------------------

local function isNull(res)
    if res == nil or res == ngx.null then
        return true
    end
    if type(res) == 'table' then
        if #res == 0 then
            return true
        end
        for _, v in pairs(res) do
            if v ~= nil and v ~= ngx.null then
                return false
            end
        end
        return true
    end
    return false
end

_M.isNull = isNull

--- 发起一条命令。命中缓存（未命中）时**仍然归还连接**。
--- @param self table
--- @param cmd string
--- @return any
--- @return string|nil err
function _M.exec(self, cmd, ...)
    local name = ALIASES[cmd] or cmd
    if not COMMANDS[name] then
        return nil, sformat('unsupported redis command: %s', tostring(cmd))
    end

    -- pipeline 缓冲阶段：只排队，不建连接
    if self._reqs then
        local n = select('#', ...)
        local row = { name, n }
        for i = 1, n do
            row[i + 1] = (select(i, ...))
        end
        tinsert(self._reqs, row)
        return true, nil
    end

    local conn, err = self:ensure()
    if not conn then
        return nil, err
    end

    local fun = conn[name]
    local res, cerr = fun(conn, ...)

    if res == nil and cerr ~= nil and cerr ~= 'timeout' then
        -- 明确的协议级错误：连接已不可信
        self:settle(false)
        return nil, sformat('%s failed: %s', name, tostring(cerr))
    end

    -- 关键修正：无论 res 是否为 nil（含**缓存未命中**这个最常见分支）都归还连接
    self:settle(true)

    if isNull(res) then
        return nil, nil
    end
    return res, nil
end

--- Lua 调用形态：r:get(key)
local function makeMethod(cmd)
    return function(self, ...)
        return _M.exec(self, cmd, ...)
    end
end

for cmd in pairs(COMMANDS) do
    _M[cmd] = makeMethod(cmd)
end

--------------------------------------------------------------------------------
-- pipeline
--------------------------------------------------------------------------------

--- 开始缓冲。缓冲期间所有命令只入队。
function _M.init_pipeline(self)
    self._reqs = {}
end

--- 发送缓冲中的命令。
--- @param self table
--- @return table[] results  与入队顺序一一对应；null 位置为 nil
--- @return string|nil err
function _M.commit_pipeline(self)
    local reqs = self._reqs
    if reqs == nil or #reqs == 0 then
        return {}, nil
    end
    self._reqs = nil

    local conn, err = self:ensure()
    if not conn then
        return nil, err
    end

    conn:init_pipeline()
    for _, row in ipairs(reqs) do
        local name, n = row[1], row[2]
        local fun = conn[name]
        if fun == nil then
            self:settle(false)
            return nil, sformat('unsupported redis command in pipeline: %s', tostring(name))
        end
        local args = {}
        for i = 1, n do
            args[i] = row[i + 2]
        end
        fun(conn, tunpack(args, 1, n))
    end

    local results, rerr = conn:commit_pipeline()
    self:settle(true)

    if results == nil then
        return nil, sformat('commit_pipeline failed: %s', tostring(rerr))
    end

    local out = {}
    for i, res in ipairs(results) do
        if isNull(res) then
            out[i] = nil
        else
            out[i] = res
        end
    end
    -- ipairs 会在第一个 nil 处停止，调用方需要按下标访问，故额外给出长度
    return out, nil, #results
end

--- 便捷封装：一次 pipeline 里取多个 key。
--- @param self table
--- @param keys string[]
--- @return table
--- @return string|nil err
function _M.mget(self, keys)
    if type(keys) ~= 'table' or #keys == 0 then
        return {}
    end
    self:init_pipeline()
    for _, k in ipairs(keys) do
        self:get(k)
    end
    local res, err, n = self:commit_pipeline()
    if res == nil then
        return nil, err
    end
    local out = {}
    for i = 1, (n or #keys) do
        out[i] = res[i]
    end
    return out
end

return _M
