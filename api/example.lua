--- 示例数据源适配器，同时也是**新增适配器的参考模板**。
---
--- 原始版本里有 12 个几乎逐字复制、却各自微调过的适配器（`mz/ad/nad/td/ntd/
--- gt/iqy/gp/bf/ify/lno/yk`）。它们共享同一段「设备标识归一化」逻辑，但白名单
--- 各不相同（`mz` 认 androidid、`yk` 和 `iqy` 不认……），且全部用手工字符串拼接
--- 生成 JSON。本文件把这套逻辑收敛成一个可单测的纯函数 + 一个正确的 `fetch`。
---
--- ## 如何新增一个适配器
--- 1. 复制本文件，改 `name` 与上游交互部分；
--- 2. 在 `conf/config.lua` 的 `dmp` 里加上名字；
--- 3. 在 `conf/system.lua` 的 `vendors.<name>` 填凭据与默认标签；
--- 4. 若走通用反代，在 `system.upstreams` 登记并填 `proxy = true`；
--- 5. `nginx -t && nginx -s reload` —— 注册表会在启动期校验契约，不合规直接拒绝加载。
---
--- ## 返回值
--- 只需返回 `env.hit(tags, elapsed)` 或 `env.fail(code, detail)`。
--- 抛异常也可以，orchestrator 会 pcall 并转成 500 信封，不会污染其他数据源。

local util = require('lib.util')
local ext = require('lib.ngx_ext')
local env = require('lib.envelope')
local http = require('lib.http')
local upstream = require('lib.upstream')

local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local sformat = string.format
local tinsert = table.insert

local m_floor = math.floor

local _M = {
    name = 'example',
    version = '2.0',
}

--------------------------------------------------------------------------------
-- 配置访问
--------------------------------------------------------------------------------

--- orchestrator 会在 init 阶段调用 `setConfig` 把已校验的配置注入进来，
--- 避免每次 fetch 都重新 require conf，也便于单测塞一份假配置。
local _cfg

--- @param cfg table
function _M.setConfig(cfg)
    _cfg = cfg
end

--- 取配置：优先用注入的，其次回落到原始 conf。
local function getCfg()
    return _cfg or require('conf.config')
end

--------------------------------------------------------------------------------
-- 设备标识归一化（纯函数，可单测）
--------------------------------------------------------------------------------

--- 支持的 mtype。
--- 原版散落的白名单互不一致，这里显式声明为唯一事实来源。
local MTYPES = {
    imei = true, imei_md5 = true,
    idfa = true, idfa_md5 = true,
    androidid = true, androidid_md5 = true,
    mac = true, mac_md5 = true,
    cookie = true,
    rmid = true,       -- 本地标识，先做映射再查上游
    unknown = true,     -- 由长度推断
}

--- 把调用方给的设备标识归一化成 `{ mtype=, value= }`。
---
--- 归一化规则（示例口径，实际按厂商要求调整）：
---   * 32 位十六进制   → imei_md5，原样转大写
---   * 36 位带连字符    → idfa_md5（UUID 形态），原样转大写
---   * mtype 显式给出且已带 _md5 后缀 → 只做大小写归一，不重复哈希
---   * mtype 为明文类型 → 按类型做大小写归一
---   * 其它             → 归到 unknown，按 imei_md5 处理并做一次 MD5
---
--- @param key string
--- @param mtype string|nil
--- @return table|nil { mtype=, value= }
--- @return string|nil err
function _M.normalizeKey(key, mtype)
    if util.isBlank(key) then
        return nil, 'key is required'
    end
    key = util.trim(key)

    local mt = (not util.isBlank(mtype)) and string.lower(mtype) or nil
    if mt ~= nil and not MTYPES[mt] then
        return nil, 'unsupported mtype: ' .. mt
    end

    local len = #key

    if mt == nil or mt == 'unknown' then
        if len == 32 then
            mt, key = 'imei_md5', string.upper(key)
        elseif len == 36 then
            mt, key = 'idfa_md5', string.upper(key)
        else
            mt = 'imei_md5'
            key = string.upper(ngx.md5(string.upper(key)))
        end
        return { mtype = mt, value = key }
    end

    if mt == 'imei' then
        key = string.lower(key)
    elseif mt == 'idfa' or mt == 'androidid' or mt == 'mac' or mt == 'cookie' then
        key = string.upper(key)
    elseif mt == 'imei_md5' then
        key = string.upper(key)
    elseif mt == 'idfa_md5' or mt == 'androidid_md5' or mt == 'mac_md5' then
        key = string.upper(ngx.md5(string.upper(key)))
    end

    return { mtype = mt, value = key }
end

--------------------------------------------------------------------------------
-- 身份映射（rmid -> 上游 uid）
--------------------------------------------------------------------------------

--- 把本地 rmid 映射成上游认识的 uid。
--- 映射来源由 `conf.cache_type` 决定（redis / cassandra）；
--- 查不到时返回 nil，由调用方转成 410，而不是继续拿原始 rmid 去查上游 ——
--- 后者正是原版 `mz.lua:28-47` 的缺陷：缓存未命中后不报错，
--- 反而把 rmid 当设备号 MD5 后发给厂商，得到一个静默错误的结果。
---
--- @param rmid string
--- @param source string
--- @param cfg table
--- @return string|nil uid
--- @return string|nil err
function _M.resolveIdentity(rmid, source, cfg)
    if util.isBlank(rmid) then
        return nil, 'rmid is required'
    end

    if cfg.cache_type == 'cassandra' then
        local cass = require('lib.cassandra')
        return cass.lookupUid(rmid, source, cfg)
    end
    local cache = require('lib.cache')
    return cache.lookupUid(rmid, source, cfg)
end

--------------------------------------------------------------------------------
-- fetch
--------------------------------------------------------------------------------

--- @param self table
--- @param params table 入参：key / mtype / tid / timeout_ms
--- @param budgetMs number 本数据源的时间预算
--- @return table envelope
function _M.fetch(self, params, budgetMs)
    local start = ngx.now()
    if type(params) ~= 'table' then
        return env.fail(env.CODES.BAD_REQUEST, 'params must be a table')
    end

    local cfg = getCfg()
    local vendor = cfg.vendors[self.name] or {}
    local normalized, nerr = _M.normalizeKey(params.key, params.mtype)
    if normalized == nil then
        return env.fail(env.CODES.BAD_REQUEST, nerr)
    end

    local key = normalized.value

    -- rmid 走映射
    if normalized.mtype == 'rmid' then
        local uid, uerr = _M.resolveIdentity(key, self.name, cfg)
        if uid == nil then
            return env.fail(env.CODES.IDENTITY_MISS, uerr)
        end
        key = uid
        normalized.mtype = vendor.upstream_mtype or 'imei_md5'
    end

    local elapsed = function()
        return m_floor((ngx.now() - start) * 1000)
    end

    -- mock 模式：不发真实请求，产出确定性结果。
    -- 让仓库 clone 下来 `curl` 一下就能看到完整链路，而不必先搭一个上游。
    if vendor.mock == true then
        local tags = {}
        local digest = ngx.md5(key)
        for i = 1, tonumber(vendor.mock_tag_count) or 2 do
            local b = tonumber(string.sub(digest, i * 2 - 1, i * 2), 16) or 0
            if b % 3 ~= 0 then
                tinsert(tags, sformat('tag_%02x', b))
            end
        end
        return env.hit(tags, elapsed())
    end

    -- 真实上游：请求体用 json_encode 生成，绝不手工拼字符串
    local upstreamName = vendor.upstream
    if util.isBlank(upstreamName) then
        return env.fail(env.CODES.INTERNAL, 'vendors.example.upstream is not configured')
    end

    local spec, serr = upstream.resolve({
        upstream = upstreamName,
        method = 'POST',
        path = '/query',
        data = ext.jsonEncode({
            idfa = normalized.value,
            type = normalized.mtype,
            tag = util.splitList(params.tid or vendor.tagID, ','),
        }),
    }, cfg, cfg.max_body_bytes)

    if spec == nil then
        return env.fail(env.CODES.INTERNAL, serr)
    end
    spec.proxy = (cfg.upstreams[upstreamName] or {}).proxy == true

    local status, body, err = http.send(spec, cfg)
    if status == nil then
        ngx.log(ngx.ERR, sformat('[dmp] %s upstream error: %s', self.name, tostring(err)))
        if tostring(err):find('timed out') then
            return env.fail(env.CODES.UPSTREAM_TIMEOUT, err, elapsed())
        end
        return env.fail(env.CODES.UPSTREAM_UNAVAILABLE, err, elapsed())
    end

    if status ~= 200 then
        return env.fail(env.CODES.NOT_FOUND, sformat('upstream returned %d', status), elapsed())
    end

    local payload, perr = ext.jsonDecode(body)
    if payload == nil then
        return env.fail(env.CODES.UPSTREAM_BAD_BODY, perr, elapsed())
    end

    -- 上游响应：形如 { "1001": 1, "1002": 0 }
    local tags = {}
    for tagId, hit in pairs(payload) do
        if hit == 1 or hit == true then
            tinsert(tags, tagId)
        end
    end
    table.sort(tags)

    return env.hit(tags, elapsed())
end

return _M
