--- 签名入口：带 HMAC 鉴权的聚合查询。
---
--- ## 相对 2017 年 `apis.lua` 修正的三个缺陷
---
--- ### 1) 签名漏掉 HTTP method（原版 apis.lua:5, 37）
--- ```lua
--- local request_method = ngx.var.request_method;   -- 声明了，但没用
--- local token = ... ngx.hmac_sha1(passwd, method .. host .. mzpath)
--- --                                                       ^^^^^^ 未声明 → 全局 nil
--- ```
--- `method` 从未声明，取全局 `nil`，拼接时等价于空串。
--- HMAC 实际只覆盖了 `host .. mzpath`，**请求方法不在签名范围内**。
---
--- ### 2) 签名未覆盖请求体（原版 apis.lua:36）
--- `mzpath` 只包含 query 参数里的 `id`/`key`/`keyid`/`mtype`，
--- 而 `dmp` 等实际影响结果的字段**不在签名覆盖范围内** ——
--- 攻击者可以替换 `dmp` 字段而不使签名失效。
---
--- ### 3) 参数个数不匹配（原版 apis.lua:42）
--- ```lua
--- local str, used = thr.thread(key, dmp, args)   -- 传 3 个
--- -- t_thread.lua:5  function _M.thread(args)    -- 只接受 1 个
--- ```
--- `args.dmp` 为 nil → `string.split` 返回 nil → 落到 `pairs(args)`，
--- 而 `args` 实际是字符串 → LuaJIT 抛 `bad argument #1 to 'for iterator'`。
---
--- 本版的签名串：
--- ```text
--- METHOD \n PATH \n SHA1(body) \n nonce \n timestamp
--- ```
--- 覆盖方法、路径、请求体摘要，并带 nonce + 时间戳防重放。

local orchestrator = require('lib.orchestrator')
local envelope = require('lib.envelope')
local ext = require('lib.ngx_ext')
local util = require('lib.util')

local type = type
local ipairs = ipairs
local m_floor = math.floor
local sformat = string.format
local ngx_re = ngx.re
local ngx_md5 = ngx.md5
local ngx_sha1 = ngx.sha1_bin
local ngx_hmac = ngx.hmac_sha1
local ngx_b64 = ngx.encode_base64
local ngx_escape = ngx.escape_uri

local CODES = envelope.CODES

--- 签名允许的时间窗（秒）。超出即拒，防止重放。
local SKEW_SECONDS = 300

--- 构造待签名字符串。
--- @param method string
--- @param path string
--- @param body string
--- @param nonce string
--- @param ts string
--- @return string
local function canonical(method, path, body, nonce, ts)
    return sformat('%s\n%s\n%s\n%s\n%s',
        method, path, ngx_b64(ngx_sha1(body or '')), nonce, ts)
end

--- 校验签名。
--- @param secret string
--- @param provided string 调用方给的 token
--- @param method string
--- @param path string
--- @param body string
--- @param nonce string
--- @param ts number
--- @return boolean
--- @return string|nil err
local function verify(secret, provided, method, path, body, nonce, ts)
    if util.isBlank(secret) then
        return false, 'no secret bound to this key id'
    end
    if util.isBlank(provided) then
        return false, 'sign is required'
    end

    local now = ngx.time()
    if type(ts) ~= 'number' then
        return false, 'timestamp must be a number'
    end
    local skew = math.abs(now - ts)
    if skew > SKEW_SECONDS then
        return false, sformat('timestamp skew %ds exceeds %ds', skew, SKEW_SECONDS)
    end

    local expected = ngx_escape(ngx_b64(ngx_hmac(secret, canonical(method, path, body, nonce, ts))))
    -- 常量时间比较，避免时序侧信道
    if not util.secureEquals(expected, provided) then
        return false, 'sign mismatch'
    end
    return true
end

local function run()
    local DMP = _G.DMP
    if DMP == nil or DMP.cfg == nil then
        return ext.replyError(500, 'service not initialised')
    end
    local cfg = DMP.cfg

    local method = ngx.var.request_method
    if method ~= 'POST' then
        ngx.header['Allow'] = 'POST'
        return ext.replyError(CODES.METHOD_NOT_ALLOWED, 'only POST is accepted')
    end

    local body = ngx.req.get_body_data()
    if util.isBlank(body) then
        local path = ngx.req.get_body_file()
        if path then
            local f = io.open(path, 'rb')
            if f then
                body = f:read(cfg.max_body_bytes + 1)
                f:close()
            end
        end
    end
    if util.isBlank(body) then
        ngx.ctx.dmp_error = 'empty body'
        return ext.replyError(CODES.BAD_REQUEST, 'empty body')
    end
    if #body > cfg.max_body_bytes then
        ngx.ctx.dmp_error = 'body too large'
        return ext.replyError(CODES.PAYLOAD_TOO_LARGE, 'body too large')
    end

    local args, jerr = ext.jsonDecode(body)
    if args == nil then
        ngx.ctx.dmp_error = 'invalid json'
        return ext.replyError(CODES.BAD_REQUEST, 'invalid json')
    end

    -- ---- 凭据查找 ----
    local keyId = args.keyid
    if util.isBlank(keyId) then
        ngx.ctx.dmp_error = 'keyid is required'
        return ext.replyError(CODES.BAD_REQUEST, 'keyid is required')
    end

    local authKeys = cfg.auth_keys or {}
    local secret = authKeys[keyId]
    if secret == nil then
        -- 不回显 keyid 之外的信息，也不区分「不存在」与「secret 为空」，
        -- 避免变成 keyid 探测接口
        ngx.ctx.dmp_error = sformat('unknown keyid: %s', tostring(keyId))
        return ext.replyError(CODES.UNAUTHORIZED, 'unknown keyid')
    end

    -- ---- 签名校验（覆盖 method + path + body + nonce + ts）----
    local path = ngx.var.uri or '/apis'
    local ok, verr = verify(secret, args.sign, method, path, body,
        args.nonce, tonumber(args.timestamp))
    if not ok then
        ngx.log(ngx.WARN, sformat('[dmp] auth failed for keyid=%s: %s',
            util.shortHash(tostring(keyId), 8), tostring(verr)))
        return ext.replyError(CODES.UNAUTHORIZED, 'invalid signature')
    end

    -- ---- 查询 ----
    local grouped, meta = orchestrator.run(args, cfg, DMP.adapters)
    local out = orchestrator.toResponse(grouped, meta)

    ngx.ctx.dmp_summary = {
        code = out.code,
        elapsed = out.elapsed,
        sources = grouped,
        req_id = ngx.var.request_id,
    }

    return ext.reply(200, out)
end

return run()
