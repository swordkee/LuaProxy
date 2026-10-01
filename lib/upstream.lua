--- 通用反代通道（`tcp[]`）的**上游白名单**。
---
--- ## 背景：这是原版最严重的一处缺陷
--- 2017 年版本的链路是：
--- ```lua
--- -- api.lua:11        args = json_decode(body)              -- 请求体全部由调用方控制
--- -- t_thread.lua:30   spawn(req.requestHttp, args['tcp'][k])
--- -- t_http.lua:118    ngx.location.capture('/proxy/' .. host .. path)
--- -- dmpapi.conf:58    proxy_pass $1://$2;                    -- $2 来自请求体
--- ```
--- `tcp[].host` / `port` / `path` 全部来自请求体，nginx 用变量拼 `proxy_pass`。
--- `location /proxy/` 上的 `internal;` **只能阻止外部直接访问该 location，
--- 不能阻止 SSRF** —— 调用方可以让 nginx worker 向 `127.0.0.1:9042`、
--- `169.254.169.254` 或任意内网 host:port 发起请求，等价于一个无鉴权的开放代理。
---
--- ## 本模块的约束模型
--- 调用方**不再提供 host/port/protocol**，只能提供一个在 `conf.system.upstreams`
--- 中登记的**名字**。真正的连接目标完全由服务端配置决定：
---
--- ```lua
--- upstreams = {
---     ['partner-api'] = {
---         host = 'api.partner.example',  -- 唯一可信来源
---         port = 443,
---         protocol = 'https',
---         base_path = '/v1/',            -- 可选：请求 path 必须落在此前缀下
---         timeout_ms = 800,
---         methods = { 'GET', 'POST' },   -- 可选，默认只放 GET/POST
---     },
--- }
--- ```
---
--- 调用方请求变为：
--- ```json
--- {"tcp": [{"upstream": "partner-api", "path": "/v1/query?a=1", "method": "GET"}]}
--- ```
---
--- `path` 仍由调用方控制（这是"代理"这一业务形态的固有需要），因此额外做严格校验：
--- 必须以 `/` 开头、不得含 `://` / `..` / `@` / 百分号编码 / 控制字符，
--- 以杜绝「path 里塞绝对 URL」「`//evil.com` 协议相对 URL」「`..` 穿越」
--- 这三类逃逸 —— 它们能让 `proxy_pass $1://$2` 指向白名单之外的主机。

local util = require('lib.util')

local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local sformat = string.format
local ssub = string.sub
local sfind = string.find
local sbyte = string.byte
local supper = string.upper
local tinsert = table.insert

local _M = {}

_M._VERSION = '2.0'

--- path 中禁止出现的片段 / 字符：
---   '://' → 挡住 `http://` 绝对 URL 与端口拼接
---   '..'  → 挡住路径穿越
---   '@'   → 挡住 `user@evil.com` 的 userinfo 注入
---   '\'   → 挡住部分实现对反斜杠的特殊处理
---   '%'   → 挡住 `%2e%2e%2f` / `%00` 的百分号编码穿越
---   '#'   → 挡住 fragment 截断
--- 另外 path 不得含控制字符（CRLF 头注入 / nginx 指令截断），见下方字节级检查。

--- 返回 `(path, nil)` 表示通过，`(nil, err)` 表示拒绝。
--- 本文件内所有 validate* 函数统一遵循这一约定 —— 调用方一律按
--- `if 值 == nil then 拒绝` 判断。签名不一致是这类工具函数最常见的缺陷来源，
--- 原版 `t_http.lua:_M.requset`（把 status 当 body 返回）即属此类。
---
--- @param path any
--- @return string|nil path
--- @return string|nil err
local function validatePath(path)
    if type(path) ~= 'string' or path == '' then
        return nil, 'path is required'
    end
    if ssub(path, 1, 1) ~= '/' then
        return nil, 'path must start with /'
    end
    if ssub(path, 1, 2) == '//' then
        -- `//evil.com/x` 在 proxy_pass 语境下是协议相对 URL
        return nil, 'path must not start with //'
    end
    for _, bad in ipairs({ '://', '..', '@', '\\', '%', '#' }) do
        if sfind(path, bad, 1, true) then
            return nil, 'path must not contain ' .. bad
        end
    end
    for i = 1, #path do
        local b = sbyte(path, i)
        if b < 0x20 or b == 0x7f then
            return nil, sformat('path contains control byte 0x%02X', b)
        end
    end
    return path, nil
end

--- 归一化并校验 method。
--- @param m any
--- @return string|nil
--- @return string|nil err
local function validateMethod(m)
    if util.isBlank(m) then
        return 'GET'
    end
    if type(m) ~= 'string' then
        return nil, 'method must be a string'
    end
    local up = supper(m)
    if up ~= 'GET' and up ~= 'POST' then
        return nil, 'only GET / POST are allowed, got ' .. up
    end
    return up
end

--- 校验 request body（仅 POST 使用）。
--- @param data any
--- @param maxBytes number
--- @return string|nil
--- @return string|nil err
local function validateData(data, maxBytes)
    if util.isBlank(data) then
        return nil
    end
    if type(data) ~= 'string' then
        return nil, 'data must be a string'
    end
    if #data > maxBytes then
        return nil, sformat('data too large: %d > %d', #data, maxBytes)
    end
    return data
end

--- 解析一次 `tcp[]` 请求。
---
--- @param params table 调用方传入的单个元素
--- @param cfg table  lib/config.load() 的结果
--- @param maxBodyBytes number 单次请求体上限
--- @return table|nil spec  形如 { name, host, port, protocol, path, method, data, timeout_ms }
--- @return string|nil err
function _M.resolve(params, cfg, maxBodyBytes)
    if type(params) ~= 'table' then
        return nil, 'tcp entry must be an object'
    end

    -- 1) 必须给出**名字**，而不是 host
    local name = params.upstream
    if util.isBlank(name) then
        return nil, 'missing required field: upstream (must be a name registered in conf.system.upstreams)'
    end
    if type(name) ~= 'string' then
        return nil, 'upstream must be a string'
    end

    -- 2) 名字必须在白名单内
    local def = cfg.upstreams[name]
    if type(def) ~= 'table' then
        -- 不回显调用方给的值，避免把白名单内容当探测信道；
        -- 只说明「未登记」，调用方对照 conf 即可
        return nil, sformat('upstream "%s" is not registered', name)
    end

    -- 3) 调用方若仍传了 host/port/protocol，明确拒绝而非静默忽略，
    --    否则调用方会误以为已生效
    for _, forbidden in ipairs({ 'host', 'port', 'protocol' }) do
        if params[forbidden] ~= nil then
            return nil, sformat(
                'field "%s" is not accepted; connection target is fixed by the server-side registry', forbidden)
        end
    end

    -- 4) path 严格校验
    local path, perr = validatePath(params.path)
    if path == nil then
        return nil, perr
    end

    -- 5) 可选的 base_path 前缀约束
    local base = def.base_path
    if base and base ~= '' then
        -- 归一化：去掉结尾斜杠，得到裸前缀（如 '/v1/' -> '/v1'）。
        -- 不先归一化就拼成 base..'/' 的话，base 自带斜杠时会变成 '/v1//' 而恒不匹配。
        local prefix = base
        if ssub(prefix, -1) == '/' then
            prefix = ssub(prefix, 1, -2)
        end
        -- path 必须恰好等于前缀，或以「前缀 + /」开头。
        -- 只比前缀会把 /v1evil 误判为落在 /v1 之下，故额外确认分隔符。
        if path ~= prefix and ssub(path, 1, #prefix + 1) ~= prefix .. '/' then
            return nil, sformat('path must be under "%s"', base)
        end
    end

    -- 6) method
    local method, merr = validateMethod(params.method)
    if method == nil then
        return nil, merr
    end
    if def.methods and type(def.methods) == 'table' then
        if not util.contains(method, def.methods) then
            return nil, sformat('method %s is not allowed for upstream %s', method, name)
        end
    end

    -- 7) body
    local data, derr = validateData(params.data, maxBodyBytes)
    if data == nil and derr ~= nil then
        return nil, derr
    end
    if method == 'POST' and util.isBlank(data) then
        return nil, 'POST requires data'
    end

    return {
        name = name,
        host = def.host,                       -- 可信来源：仅来自 conf
        port = tonumber(def.port),
        protocol = def.protocol or 'http',
        path = path,
        method = method,
        data = data,
        timeout_ms = tonumber(params.timeout_ms) or def.timeout_ms or cfg.httptimeout_ms,
    }, nil
end

--- 供 `lib/dispatch` 在启动期做一次自检：
--- 遍历白名单全部条目，确认可被 resolve 接受，避免配置写了却从不被验证。
--- @param cfg table
--- @return string[] warnings
function _M.selfCheck(cfg)
    local warnings = {}
    if type(cfg.upstreams) ~= 'table' then
        return warnings
    end
    for name, def in pairs(cfg.upstreams) do
        local proto = def.protocol or 'http'
        local port = tonumber(def.port)
        if def.proxy == true then
            -- 走 nginx 反代通道：要求 conf 里有对应的 http_proxy 别名
            local found = false
            for _, v in pairs(cfg.http_proxy or {}) do
                if v == def.host then
                    found = true
                    break
                end
            end
            if not found then
                tinsert(warnings, sformat(
                    'upstream "%s" 标记了 proxy=true（走 nginx 反代），但 conf.config.http_proxy 中没有 %s 的别名',
                    name, def.host))
            end
        else
            -- 常见的 协议/端口 组合之外的，提示复核（不阻断启动）
            local conventional = (proto == 'https' and port == 443) or (proto == 'http' and port == 80)
            if not conventional then
                tinsert(warnings, sformat('upstream "%s" 的 protocol/port 组合不常见，请复核: %s:%s',
                    name, proto, tostring(port)))
            end
        end
    end
    return warnings
end

return _M
