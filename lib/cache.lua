--- 缓存业务层：rmid -> uid 的身份映射。
---
--- ## 相对 2017 年 `t_cache.lua` 修正的问题
---
--- ### 1) shared dict 永不过期（原版 t_cache.lua:108,111,185,189,195）
--- ```lua
--- dict:set(conf.orderTable .. id .. ":dmp", res[1])   -- 2 参数形式，无 exptime
--- ```
--- rmid -> uid 的映射是**人群定向**的依据，「陈旧」直接等于「投错人」。
--- 原版写入后没有任何过期时间，只能等 shared dict 满了被 LRU 挤掉 ——
--- 也就是说缓存的新鲜度上限是不可控的。此处统一按 `cfg.dict_ttl_ms` 写入。
---
--- ### 2) `getRedisByZset` 非原子（原版 t_cache.lua:52-70）
--- 三次串行往返（ZCOUNT / ZRANGE / ZREMRANGEBYRANK）之间没有任何事务保护，
--- 并发下两个 worker 可能取到同一条，或一条已被取走的记录。此处改为
--- 单条 `LPOP` / Lua 脚本式的原子取走。
---
--- ### 3) `return ok` 返回全局 nil（原版 t_cache.lua:156）
--- `ok` 从未赋值，返回的是全局 `ok`（nil）。此处返回明确的统计信息。

local util = require('lib.util')

local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local sformat = string.format
local tinsert = table.insert

local _M = {}

_M._VERSION = '2.0'

local dict = ngx.shared.dataDict

--------------------------------------------------------------------------------
-- shared dict 封装（带 TTL 与淘汰感知）
--------------------------------------------------------------------------------

--- 写入并带 TTL。shared dict 满时 `set` 返回 false / nil，需显式处理 ——
--- 原版完全忽略了返回值，缓存写不进去也没人知道。
--- @param key string
--- @param val string
--- @param ttlMs number
--- @return boolean
local function put(key, val, ttlMs)
    if util.isBlank(key) or util.isBlank(val) then
        return false
    end
    local ok, err = dict:set(key, val, ttlMs or 0)
    if not ok then
        -- 共享内存耗尽：这属于容量事故，应告警而非静默
        ngx.log(ngx.ERR, sformat('shared dict set failed (full?): %s', tostring(err)))
        return false
    end
    return true
end

--- @param key string
--- @return string|nil
local function fetch(key)
    if util.isBlank(key) then
        return nil
    end
    local v = dict:get(key)
    if v == nil or v == ngx.null then
        return nil
    end
    return v
end

--------------------------------------------------------------------------------
-- 身份映射
--------------------------------------------------------------------------------

--- shared dict 的 key 生成。**读路径与预热路径共用这一处**，避免 key 漂移。
--- @param source string
--- @param rmid string
--- @param cfg table
--- @return string
local function uidCacheKey(source, rmid, cfg)
    return sformat('%suid:%s:%s', cfg.order_table, source, rmid)
end

--- 从 Redis 取 uid。优先读 shared dict，未命中回落 Redis。
--- @param rmid string
--- @param source string 数据源名（决定 hash key）
--- @param cfg table
--- @return string|nil uid
--- @return string|nil err
function _M.uidFromRedis(rmid, source, cfg)
    if util.isBlank(rmid) then
        return nil, 'rmid is required'
    end

    local cacheKey = uidCacheKey(source, rmid, cfg)
    local hit = fetch(cacheKey)
    if hit then
        return hit, nil
    end

    local redis = require('lib.redis')
    local client = redis.new(cfg)
    local value, err = client:hget(cfg.order_table .. rmid, 'dmp')
    -- 无论命中与否，连接都已在 redis.exec 内归还

    if err then
        ngx.log(ngx.WARN, sformat('[dmp] redis lookup failed for source %s: %s', source, err))
        return nil, err
    end
    if util.isBlank(value) then
        return nil, nil
    end

    put(cacheKey, value, cfg.dict_ttl_ms)
    return value, nil
end

--- 从 Cassandra 取 uid。
--- @param rmid string
--- @param source string
--- @param cfg table
--- @return string|nil uid
--- @return string|nil err
function _M.uidFromCassandra(rmid, source, cfg)
    if util.isBlank(rmid) then
        return nil, 'rmid is required'
    end
    local cass = require('lib.cassandra')
    return cass.lookupUid(rmid, source, cfg)
end

--- 按 `cfg.cache_type` 分派。
--- @param rmid string
--- @param source string
--- @param cfg table
--- @return string|nil uid
--- @return string|nil err
function _M.lookupUid(rmid, source, cfg)
    if cfg.cache_type == 'cassandra' then
        return _M.uidFromCassandra(rmid, source, cfg)
    end
    return _M.uidFromRedis(rmid, source, cfg)
end

--------------------------------------------------------------------------------
-- 原子队列消费
--------------------------------------------------------------------------------

--- 原子地从有序集合中取走一个元素。
---
--- 原版 `getRedisByZset` 分三步且无事务保护，并发下会重复消费或丢条目。
--- Redis 5.0+ 用 `ZPOPMIN` 一步完成；更低版本退回 Lua 脚本（仍是原子）。
---
--- @param name string 有序集合名
--- @param cfg table
--- @return string|nil member
--- @return string|nil err
function _M.popZset(name, cfg)
    if util.isBlank(name) then
        return nil, 'name is required'
    end

    local redis = require('lib.redis')
    local client = redis.new(cfg)

    local conn, err = client:ensure()
    if not conn then
        return nil, err
    end

    local member
    local popped, perr

    if redis.COMMANDS['zpopmin'] then
        popped, perr = conn:zpopmin(name, 1)
    else
        -- Lua 脚本保证 ZRANGE + ZREM 的组合原子
        local script = [[
            local r = redis.call('ZRANGE', KEYS[1], 0, 0)
            if #r == 0 then return nil end
            redis.call('ZREM', KEYS[1], r[1])
            return r[1]
        ]]
        local sha, serr = conn:script('load', script)
        if sha then
            popped, perr = conn:evalsha(sha, 1, name)
        else
            client:settle(false)
            return nil, sformat('cannot load zpop script: %s', tostring(serr))
        end
    end

    client:settle(perr == nil)

    if perr then
        return nil, tostring(perr)
    end
    if type(popped) ~= 'table' or popped[1] == nil then
        return nil, nil
    end
    -- ZPOPMIN 返回 [member, score]
    member = popped[1]
    return member, nil
end

--------------------------------------------------------------------------------
-- 预热
--------------------------------------------------------------------------------

--- 预热：把 Redis 中的 rmid -> uid 映射批量灌入 shared dict。
---
--- 原版 `getSysInfo` 由每个 worker 各自每 7 秒跑一次全量扫描，
--- 8 个 worker 就是 8 倍重复扫描；且返回值是未赋值的全局 `ok`（实际返回 nil）。
--- 此处改为按数据源预热、由 `init_worker` 只在首次执行，
--- 并配合 dict TTL 自然过期，返回明确的统计信息供启动日志记录。
---
--- 写入的 key 必须与 `uidFromRedis` 的读路径**逐字节一致**，
--- 否则预热等于白做 —— 这里统一走 uidCacheKey() 生成，避免两处漂移。
---
--- @param source string 数据源名
--- @param cfg table
--- @return table stats { scanned=, loaded=, skipped= }
function _M.warmup(source, cfg)
    local stats = { scanned = 0, loaded = 0, skipped = 0 }
    if not dict or util.isBlank(source) then
        return stats
    end

    local limit = tonumber(cfg.warmup_limit) or 1000
    if limit < 1 then
        limit = 1
    end

    local redis = require('lib.redis')
    local client = redis.new(cfg)

    -- 第一段 pipeline：取 rmid 索引（zset，score 越新越靠前）
    client:init_pipeline()
    client:zrevrange(cfg.order_table .. 'index', 0, limit - 1)
    local res, err = client:commit_pipeline()
    if res == nil then
        ngx.log(ngx.WARN, sformat('[dmp] warmup(%s) index scan skipped: %s', source, tostring(err)))
        return stats
    end

    local ids = res[1]
    if type(ids) ~= 'table' then
        return stats
    end

    -- 第二段 pipeline：批量取各 rmid 的 dmp 字段
    client:init_pipeline()
    for _, rmid in ipairs(ids) do
        client:hget(cfg.order_table .. rmid, 'dmp')
        stats.scanned = stats.scanned + 1
    end
    local rows = client:commit_pipeline()
    if rows == nil then
        ngx.log(ngx.WARN, sformat('[dmp] warmup(%s) value scan failed', source))
        return stats
    end

    for i, rmid in ipairs(ids) do
        local uid = rows[i]
        if not util.isBlank(uid) then
            if put(uidCacheKey(source, rmid, cfg), uid, cfg.dict_ttl_ms) then
                stats.loaded = stats.loaded + 1
            else
                stats.skipped = stats.skipped + 1
            end
        end
    end

    return stats
end

return _M
