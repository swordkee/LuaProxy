--- Cassandra 客户端。
---
--- ## 相对 2017 年 `t_cassandra.lua` 修正的问题
---
--- ### 1) 每次请求都新建 cluster（原版 t_cassandra.lua:10-28）
--- ```lua
--- function _M.new(self, params)
---     local options = { contact_points = conf.cassandra.ip, ... }
---     local db, err = cluster.new(options)     -- ← 每次调用
--- ```
--- `cluster.new()` 会触发 contact_points 协商（配置里
--- `max_schema_consensus_wait = 10000`）。README 记录的
--- 「已知问题：第一次请求比较慢」正源于此。
--- 本版按 **worker 维度**缓存 cluster 实例，协商只发生一次。
---
--- ### 2) 返回值类型混乱（原版 t_cassandra.lua:37-39, 51-53, 68-69）
--- `execute` / `batch` / `dmpCall` 在失败时返回 `500, '{"code":500,...}'`
--- —— 把「HTTP 状态码」和「已序列化的 JSON 字符串」混在一个返回值里，
--- 调用方无从判断到底拿到的是什么。此处一律返回 `nil, err`。

local util = require('lib.util')

local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local sformat = string.format
local tconcat = table.concat

local _M = {}

_M._VERSION = '2.0'

--- worker 私有的 cluster 缓存（key = options 指纹）。
local _clusters = {}

--- 构造 options。
--- @param cfg table
--- @return table
local function buildOptions(cfg)
    local cass = cfg.cassandra
    return {
        shm = cass.lua_shared_dict,
        contact_points = cass.ip,
        keyspace = cass.keyspace,
        timeout_read = cass.timeout_read_ms,
        timeout_connect = cass.timeout_connect_ms,
        lock_timeout = cass.lock_timeout_ms / 1000,
        protocol_version = cass.protocol_version,
        ssl = cass.ssl,
        verify = cass.verify,
    }
end

--- 获取（并在 worker 内缓存）cluster 实例。
--- @param cfg table
--- @return table|nil cluster
--- @return string|nil err
function _M.get(cfg)
    local cass = cfg.cassandra
    local auth = cass.auth
    -- 指纹包含所有影响连接的字段，避免改了配置却命中旧实例
    local fingerprint = tconcat({
        cass.keyspace or '',
        cass.protocol_version or '',
        tostring(cass.ssl),
        auth and auth[1] or '',
        auth and auth[2] or '',
        tconcat(cass.ip or {}, ','),
    }, '|')

    local cached = _clusters[fingerprint]
    if cached then
        return cached
    end

    local clusterMod = require('resty.cassandra.cluster')
    local options = buildOptions(cfg)

    local db, err = clusterMod.new(options)
    if not db then
        return nil, sformat('cannot create cassandra cluster: %s', tostring(err))
    end

    if auth and auth[1] and auth[1] ~= '' then
        local aok, aerr = db:connect(options.contact_points, auth[1], auth[2])
        if not aok then
            return nil, sformat('cassandra auth failed: %s', tostring(aerr))
        end
    end

    _clusters[fingerprint] = db
    return db
end

--- 清空缓存（配置热更新 / 单测用）。
function _M.reset()
    _clusters = {}
end

--- 查 rmid -> uid。
---
--- 表名来自 conf 且已被 `lib/config.lua` 校验为纯标识符，
--- 因此 `sformat` 拼接是安全的；**值仍然走占位符绑定**。
---
--- @param rmid string
--- @param source string
--- @param cfg table
--- @return string|nil uid
--- @return string|nil err
function _M.lookupUid(rmid, source, cfg)
    if util.isBlank(rmid) then
        return nil, 'rmid is required'
    end

    local def = cfg.cassandra.vendors[source]
    if def == nil then
        return nil, sformat('no cassandra table configured for source "%s"', source)
    end

    local db, err = _M.get(cfg)
    if db == nil then
        return nil, err
    end

    local sql = sformat('SELECT uid FROM %s.%s WHERE rmid = ? LIMIT 1',
        cfg.cassandra.keyspace, def.table)

    local res, qerr = db:execute(sql, { rmid })
    if not res then
        return nil, sformat('cassandra query failed: %s', tostring(qerr))
    end

    if type(res) ~= 'table' or res[1] == nil then
        return nil, nil
    end

    local uid = res[1].uid
    if util.isBlank(uid) then
        return nil, nil
    end
    return uid, nil
end

--- 批量查（一次 execute 多行 IN 查询）。
--- @param rmids string[]
--- @param source string
--- @param cfg table
--- @return table map  rmid -> uid
--- @return string|nil err
function _M.lookupUids(rmids, source, cfg)
    local out = {}
    if type(rmids) ~= 'table' or #rmids == 0 then
        return out
    end

    local def = cfg.cassandra.vendors[source]
    if def == nil then
        return nil, sformat('no cassandra table configured for source "%s"', source)
    end

    local db, err = _M.get(cfg)
    if db == nil then
        return nil, err
    end

    local sql = sformat('SELECT rmid, uid FROM %s.%s WHERE rmid IN ?',
        cfg.cassandra.keyspace, def.table)

    local res, qerr = db:execute(sql, { rmids })
    if not res then
        return nil, sformat('cassandra batch query failed: %s', tostring(qerr))
    end

    if type(res) ~= 'table' then
        return out
    end
    for _, row in ipairs(res) do
        if row and row.rmid and row.uid then
            out[row.rmid] = row.uid
        end
    end
    return out
end

return _M
