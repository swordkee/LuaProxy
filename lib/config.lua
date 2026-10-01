--- 配置装载与**启动期校验**。
---
--- ## 解决的问题
--- 2017 年版本的 `conf/*.lua` 是裸表，`require` 进来就直接用。任何一个 key 拼错
--- （例如 `cache.redisCluster.mz` 写成 `cache.redisCluster.redis`）都要等到线上第一次
--- 请求命中该分支才会以 `attempt to index a nil value` 的形式暴露，而且没有任何
--- 堆栈能指向「配置写错了」。
---
--- 本模块在 `init_by_lua` 阶段一次性装载 + 校验 + 归一化，任何一处不合法都让
--- `nginx -s reload` 直接失败（配置错误应尽早暴露，而不是在运行中静默降级）。
---
--- ## 单位约定
--- 原版 `httptimeout = 20` 注释写「ms」但全链路按 ms 使用，20ms 对跨网段上游
--- 明显偏紧，且语义模糊。本版本所有超时一律以 **`_ms` 后缀**显式声明，
--- 不再出现无单位的裸数字。

local util = require('lib.util')

local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local sformat = string.format
local tinsert = table.insert
local tconcat = table.concat

local _M = {}

_M._VERSION = '2.0'

--- 校验失败时的错误对象。
--- 实现 __tostring 是必需的：init.lua 会把 err 拼进 error() 的消息，
--- 若对象无法转成可读字符串，运维在 nginx 启动日志里只会看到
--- "table: 0x7f..."，完全看不到是哪一项配置错了。
local ConfigError = {}
ConfigError.__index = ConfigError

function ConfigError.__tostring(self)
    return tostring(self.message)
end

function ConfigError.__concat(self, other)
    return tostring(self) .. tostring(other)
end

--- @param msg string
--- @return table
function _M.err(msg)
    return setmetatable({ message = msg }, ConfigError)
end

--- 汇总所有校验错误，一次性报全部，避免"改一个报一个"。
--- @param errs string[]
--- @param section string
--- @return table|nil error
local function failAll(errs, section)
    if #errs == 0 then
        return nil
    end
    local lines = { sformat('config[%s] 校验未通过，共 %d 项:', section, #errs) }
    for i, e in ipairs(errs) do
        lines[i + 1] = '  ' .. i .. '. ' .. e
    end
    return _M.err(table.concat(lines, '\n'))
end

--------------------------------------------------------------------------------
-- 校验原语
--------------------------------------------------------------------------------

--- 必填标量。
local function reqScalar(tbl, key, path, errs)
    local v = tbl[key]
    local vt = type(v)
    if vt ~= 'string' and vt ~= 'number' and vt ~= 'boolean' then
        tinsert(errs, sformat('%s 必须是 string/number/boolean，实际为 %s', path, vt))
        return nil
    end
    if vt == 'string' and v == '' then
        tinsert(errs, path .. ' 不能为空串')
        return nil
    end
    return v
end

--- 必填正数（用于超时 / 池容量）。
local function reqPositive(tbl, key, path, errs)
    local v = tonumber(tbl[key])
    if v == nil then
        tinsert(errs, sformat('%s 必须是数字，实际为 %s', path, type(tbl[key])))
        return nil
    end
    if v <= 0 then
        tinsert(errs, sformat('%s 必须 > 0，实际为 %s', path, tostring(v)))
        return nil
    end
    return v
end

--- 必填表。
local function reqTable(tbl, key, path, errs)
    local v = tbl[key]
    if type(v) ~= 'table' then
        tinsert(errs, sformat('%s 必须是 table，实际为 %s', path, type(v)))
        return nil
    end
    return v
end

--------------------------------------------------------------------------------
-- 装载
--------------------------------------------------------------------------------

--- 装载并校验全部配置。
--- 必须在 `init_by_lua` 阶段调用（此时 ngx 可用，但不发起任何 IO）。
--- @return table cfg  @return table|nil err
function _M.load()
    local cfg = {}

    ------------------------------------------------------------------ config
    local ok, raw = pcall(require, 'conf.config')
    if not ok then
        return nil, _M.err('无法加载 conf/config.lua: ' .. tostring(raw))
    end

    local errs = {}

    local dmp_list = reqTable(raw, 'dmp', 'config.dmp', errs)
    local http_proxy = reqTable(raw, 'http_proxy', 'config.http_proxy', errs)
    local rsyslog = reqTable(raw, 'rsyslog', 'config.rsyslog', errs)

    local httptimeout_ms = reqPositive(raw, 'httptimeout_ms', 'config.httptimeout_ms', errs)
    local connect_timeout_ms = reqPositive(raw, 'connect_timeout_ms', 'config.connect_timeout_ms', errs)
    local source_budget_ms = reqPositive(raw, 'source_budget_ms', 'config.source_budget_ms', errs)
    local request_budget_ms = reqPositive(raw, 'request_budget_ms', 'config.request_budget_ms', errs)
    local mysqltimeout_ms = reqPositive(raw, 'mysqltimeout_ms', 'config.mysqltimeout_ms', errs)
    local pool_size = reqPositive(raw, 'pool_size', 'config.pool_size', errs)
    local pool_max_idle_time_ms = raw.pool_max_idle_time_ms
    if type(pool_max_idle_time_ms) ~= 'number' or pool_max_idle_time_ms < 0 then
        tinsert(errs, 'config.pool_max_idle_time_ms 必须是非负数（0 表示不超时）')
        pool_max_idle_time_ms = 0
    end
    local dict_ttl_ms = reqPositive(raw, 'dict_ttl_ms', 'config.dict_ttl_ms', errs)
    local max_body_bytes = reqPositive(raw, 'max_body_bytes', 'config.max_body_bytes', errs)

    -- TLS 校验开关。默认必须为 true：
    -- 关掉它意味着上游响应可被中间人伪造，而调用方无从察觉。
    -- 仅允许显式设置 false，不允许填非布尔值（否则一个拼写错误就会静默关掉校验）。
    local ssl_verify = raw.ssl_verify
    if ssl_verify == nil then
        ssl_verify = true
    elseif type(ssl_verify) ~= 'boolean' then
        tinsert(errs, 'config.ssl_verify 必须是 boolean（关闭证书校验会使上游响应可被伪造）')
        ssl_verify = true
    end

    local debug = raw.DEBUG
    if type(debug) ~= 'boolean' then
        tinsert(errs, 'config.DEBUG 必须是 boolean')
        debug = false
    end

    local log_format = reqScalar(raw, 'log_format', 'config.log_format', errs)
    if log_format ~= 'file' and log_format ~= 'rsyslog' and log_format ~= 'none' then
        tinsert(errs, 'config.log_format 只允许 file / rsyslog / none')
        log_format = 'file'
    end

    -- 请求级时间预算必须 >= 单数据源预算，否则单源超时会互相打架
    if request_budget_ms and source_budget_ms and request_budget_ms < source_budget_ms then
        tinsert(errs, sformat(
            'config.request_budget_ms(%s) 必须 >= config.source_budget_ms(%s)',
            tostring(request_budget_ms), tostring(source_budget_ms)))
    end

    local e = failAll(errs, 'config')
    if e then return nil, e end

    ----------------------------------------------------------------- system
    local ok2, sys = pcall(require, 'conf.system')
    if not ok2 then
        return nil, _M.err('无法加载 conf/system.lua: ' .. tostring(sys))
    end

    local errs2 = {}

    -- 上游白名单：tcp[] 通用反代通道**只能**命中这里登记的目标
    local upstreams = reqTable(sys, 'upstreams', 'system.upstreams', errs2)
    if upstreams then
        for name, def in pairs(upstreams) do
            local p = 'system.upstreams.' .. name
            if type(name) ~= 'string' or name == '' then
                tinsert(errs2, 'system.upstreams 的键必须是非空字符串（将作为调用方传入的 upstream 参数）')
            end
            if type(def) ~= 'table' then
                tinsert(errs2, p .. ' 必须是 table')
            else
                local host = def.host
                local port = tonumber(def.port)
                local proto = def.protocol or 'http'
                if type(host) ~= 'string' or host == '' then
                    tinsert(errs2, p .. '.host 必须是非空字符串')
                elseif host:find('[/@?#\\]') or host:find(':%d') then
                    -- 挡掉 "evil.com:6379/"、"user@host"、"a/b" 这类会让
                    -- proxy_pass $scheme://$host 逃逸出预期的写法
                    tinsert(errs2, p .. '.host 含非法字符（不允许 / @ ? # \\ 或端口后缀）: ' .. tostring(host))
                end
                if port == nil or port <= 0 or port > 65535 then
                    tinsert(errs2, p .. '.port 必须是 1-65535 的整数')
                end
                if proto ~= 'http' and proto ~= 'https' then
                    tinsert(errs2, p .. '.protocol 只允许 http / https')
                end
                if def.base_path ~= nil and type(def.base_path) ~= 'string' then
                    tinsert(errs2, p .. '.base_path 必须是字符串')
                elseif type(def.base_path) == 'string' and def.base_path ~= ''
                        and def.base_path:sub(1, 1) ~= '/' then
                    tinsert(errs2, p .. '.base_path 必须以 / 开头')
                end
                if def.timeout_ms ~= nil then
                    local t = tonumber(def.timeout_ms)
                    if t == nil or t <= 0 then
                        tinsert(errs2, p .. '.timeout_ms 必须是正数')
                    end
                end
            end
        end
    end

    -- 每个数据源的凭据/标签配置
    local vendors = reqTable(sys, 'vendors', 'system.vendors', errs2)
    if vendors and dmp_list then
        for _, name in ipairs(dmp_list) do
            if type(vendors[name]) ~= 'table' then
                tinsert(errs2, sformat(
                    'config.dmp 声明了数据源 "%s"，但 system.vendors.%s 缺失', name, name))
            end
        end
    end
    if vendors then
        for name, v in pairs(vendors) do
            if type(v) ~= 'table' then
                tinsert(errs2, 'system.vendors.' .. tostring(name) .. ' 必须是 table')
            end
        end
    end

    local e2 = failAll(errs2, 'system')
    if e2 then return nil, e2 end

    ------------------------------------------------------------------ cache
    local ok3, cache = pcall(require, 'conf.cache')
    if not ok3 then
        return nil, _M.err('无法加载 conf/cache.lua: ' .. tostring(cache))
    end

    local errs3 = {}
    local redis = reqTable(cache, 'redis', 'cache.redis', errs3)
    if redis then
        reqScalar(redis, 'host', 'cache.redis.host', errs3)
        reqPositive(redis, 'port', 'cache.redis.port', errs3)
        reqPositive(redis, 'timeout_ms', 'cache.redis.timeout_ms', errs3)
        reqPositive(redis, 'pool_size', 'cache.redis.pool_size', errs3)
    end
    local clusters = reqTable(cache, 'redis_clusters', 'cache.redis_clusters', errs3)
    if clusters and vendors then
        -- 集群键必须与 vendors 的数据源名对齐，否则 t_cache 按 source 查表会索引 nil
        for name in pairs(clusters) do
            if type(vendors[name]) ~= 'table' then
                tinsert(errs3, sformat(
                    'cache.redis_clusters 声明了 "%s"，但 system.vendors.%s 缺失（键必须与数据源名一致）',
                    name, name))
            end
        end
    end
    if clusters then
        for name, nodes in pairs(clusters) do
            if type(nodes) ~= 'table' or #nodes == 0 then
                tinsert(errs3, 'cache.redis_clusters.' .. tostring(name) .. ' 必须是非空节点数组')
            else
                for i, n in ipairs(nodes) do
                    if type(n) ~= 'table' or tonumber(n.port) == nil then
                        tinsert(errs3, sformat('cache.redis_clusters.%s[%d] 必须是含 host/port 的 table', name, i))
                    end
                end
            end
        end
    end
    local e3 = failAll(errs3, 'cache')
    if e3 then return nil, e3 end

    -------------------------------------------------------------- cassandra
    local ok4, cass = pcall(require, 'conf.cassandra')
    if not ok4 then
        return nil, _M.err('无法加载 conf/cassandra.lua: ' .. tostring(cass))
    end

    local errs4 = {}
    local cass_vendors = reqTable(cass, 'vendors', 'cassandra.vendors', errs4)
    if cass_vendors and vendors then
        for name in pairs(cass_vendors) do
            if type(vendors[name]) ~= 'table' then
                tinsert(errs4, sformat(
                    'cassandra.vendors 声明了 "%s"，但 system.vendors.%s 缺失', name, name))
            end
        end
    end
    if cass_vendors then
        for name, v in pairs(cass_vendors) do
            if type(v) ~= 'table' or type(v.table) ~= 'string' or not v.table:match('^[%w_]+$') then
                -- 表名必须是纯标识符，因为 CQL 不支持占位符绑定表名
                tinsert(errs4, sformat(
                    'cassandra.vendors.%s.table 必须是纯标识符（仅字母/数字/下划线），实际: %s',
                    tostring(name), tostring(type(v) == 'table' and v.table)))
            end
        end
    end
    local e4 = failAll(errs4, 'cassandra')
    if e4 then return nil, e4 end

    ------------------------------------------------------------------ 汇总
    cfg.DEBUG = debug
    cfg.log_format = log_format
    cfg.rsyslog = rsyslog

    cfg.httptimeout_ms = httptimeout_ms
    cfg.connect_timeout_ms = connect_timeout_ms
    cfg.source_budget_ms = source_budget_ms
    cfg.request_budget_ms = request_budget_ms
    cfg.mysqltimeout_ms = mysqltimeout_ms
    cfg.pool_size = pool_size
    cfg.pool_max_idle_time_ms = pool_max_idle_time_ms
    cfg.dict_ttl_ms = dict_ttl_ms
    cfg.max_body_bytes = max_body_bytes
    cfg.ssl_verify = ssl_verify

    cfg.dmp = dmp_list
    cfg.vendors = sys.vendors
    cfg.upstreams = sys.upstreams
    cfg.redis = cache.redis
    cfg.redis_clusters = cache.redis_clusters or {}
    cfg.order_table = cache.order_table
    cfg.service_table = cache.service_table
    cfg.cassandra = cass

    cfg.http_proxy = http_proxy
    -- 反代别名 -> 目标 host，在 init 阶段求逆一次（原版每次请求重建 invert 表）
    cfg.http_proxy_reverse = util.invert(http_proxy)

    return cfg
end

return _M
