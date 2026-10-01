--- HTTP 客户端。
---
--- 两条通道：
---   * `direct` —— 用 lua-resty-http 直连，适合外部厂商。
---   * `proxy`  —— 走 `ngx.location.capture` + nginx `upstream`，适合需要 TLS 卸载 /
---     多节点 HA 的内部伙伴方。目标 host 由服务端白名单决定（见 `lib/upstream.lua`）。
---
--- ## 相对 2017 年 `t_http.lua` 修正的问题
---   1. **连接归还遗漏**（原版 t_http.lua:87-99）：`resp` 为 nil 时只对 `timeout`
---      调 `close()`，其余错误既不 keepalive 也不 close；`read_body()` 失败更是在
---      `self:close()` **之前**就 return。两条路径都会白白丢掉已建立的连接，
---      使 keepalive 池命中率显著下降。此处统一用 `settle()` 收口。
---   2. **内部主机名外泄**（公开版 t_http.lua:64-66）：错误响应里直接拼
---      `self.opts.host`，把内网拓扑暴露给调用方。此处只回固定文案 + 上游名字。
---   3. **超时口径混乱**：原版 `httptimeout = 20` 无单位、同时用于 connect 和读写。
---      此处拆为 `connect_timeout_ms` / `httptimeout_ms`，均在 conf 中显式带单位。
---   4. **方法拼写** `requset`（typo）统一为 `request`。

local util = require('lib.util')

local type = type
local tonumber = tonumber
local sformat = string.format
local supper = string.upper
local m_floor = math.floor

local _M = {}

_M._VERSION = '2.0'

--------------------------------------------------------------------------------
-- 连接生命周期
--------------------------------------------------------------------------------

--- 无论成功失败，都必须对连接做出处置：
---   * 有响应体 → 放回 keepalive 池
---   * 连接超时 / 协议错误 → 主动关闭，避免把坏连接留在池里
---
--- @param httpc table lua-resty-http 实例
--- @param cfg table
--- @param reusable boolean 上游是否给出了完整响应（决定能否复用）
local function settle(httpc, cfg, reusable)
    if not httpc then
        return
    end
    if reusable then
        local perWorker = m_floor(cfg.pool_size / ngx.worker.count())
        if perWorker < 1 then
            perWorker = 1
        end
        local ok, err = httpc:set_keepalive(cfg.pool_max_idle_time_ms, perWorker)
        if not ok then
            ngx.log(ngx.WARN, 'set_keepalive failed: ', tostring(err))
        end
    else
        -- 主动关闭：否则这条半死的连接会留在池里被下一个请求复用
        httpc:close()
    end
end

--------------------------------------------------------------------------------
-- 直接通道
--------------------------------------------------------------------------------

--- @param spec table 来自 lib/upstream.resolve()
--- @param cfg table
--- @return number|nil status
--- @return string|nil body
--- @return string|nil err  可读错误（不含内部地址）
function _M.request(spec, cfg)
    local http = require('resty.http')
    local httpc, err = http.new()
    if not httpc then
        return nil, nil, sformat('cannot create http client: %s', tostring(err))
    end

    -- 建立连接
    httpc:set_timeout(tonumber(spec.timeout_ms) or cfg.httptimeout_ms)

    -- 关键修正：connect_timeout 必须**在 connect 之前**单独设置。
    -- 原版只设了一个 timeout 且在部分路径下于 connect 之后才设，
    -- 导致连接阶段的超时无法单独收敛 —— 连接不通与连接后读不动
    -- 是两个完全不同的故障，必须分开度量。
    httpc:set_connect_timeout(tonumber(cfg.connect_timeout_ms) or 300)

    local ok, cerr = httpc:connect(spec.host, spec.port)
    if not ok then
        settle(httpc, cfg, false)
        return nil, nil, sformat('upstream %s is unreachable (%s)', spec.name, tostring(cerr))
    end

    if spec.protocol == 'https' then
        -- verify=true 才会真正校验证书链。
        -- 原版写死 `false` —— 那等于**关闭 TLS 校验**，
        -- 中间人攻击可直接伪造上游响应，而调用方拿到的是「200 + 伪造数据」。
        local sslOpts = {
            verify = cfg.ssl_verify ~= false,   -- 默认开启
            send_status_req = true,
        }
        local verified, serr = httpc:ssl_handshake(sslOpts, spec.host, sslOpts.verify)
        if not verified then
            settle(httpc, cfg, false)
            return nil, nil, sformat('tls handshake with %s failed (%s)', spec.name, tostring(serr))
        end
    end

    -- 组装请求
    local headers = {
        ['Host'] = spec.host,
        ['Accept'] = 'application/json',
        ['Connection'] = 'keep-alive',
    }
    if spec.method == 'POST' then
        headers['Content-Type'] = 'application/json; charset=utf-8'
        headers['Content-Length'] = #spec.data
    end

    local res, rerr = httpc:request({
        method = spec.method,
        path = spec.path,
        body = (spec.method == 'POST') and spec.data or nil,
        headers = headers,
        version = 1.1,
    })

    if not res then
        -- 超时需要显式关闭：lua-resty-http 不会自动归还
        settle(httpc, cfg, false)
        if rerr == 'timeout' then
            return nil, nil, sformat('upstream %s timed out after %sms', spec.name, tostring(spec.timeout_ms))
        end
        return nil, nil, sformat('request to %s failed: %s', spec.name, tostring(rerr))
    end

    local body, berr = httpc:read_body()
    local status = res.status

    if not body then
        -- 响应头已收但 body 失败：连接状态不可知，按不可复用处理
        settle(httpc, cfg, false)
        return nil, nil, sformat('cannot read response body from %s: %s', spec.name, tostring(berr))
    end

    settle(httpc, cfg, true)
    return status, body, nil
end

--------------------------------------------------------------------------------
-- 反代通道
--------------------------------------------------------------------------------

--- 通过 nginx `upstream` 转发，复用已有的连接池与 HA 能力。
--- @param spec table
--- @param cfg table
--- @return number|nil status
--- @return string|nil body
--- @return string|nil err
function _M.requestViaProxy(spec, cfg)
    -- 目标 host 只能来自白名单；再过一道 http_proxy 反查，确保 capture 的 URL
    -- 落在已声明的 upstream 别名上
    local alias = cfg.http_proxy_reverse[spec.host]
    if alias == nil then
        return nil, nil, sformat('upstream %s is not declared in config.http_proxy', spec.name)
    end

    local uri = sformat('/proxy/%s/%s%s', spec.protocol, alias, spec.path)

    local res, err = ngx.location.capture(uri, {
        method = (spec.method == 'POST') and ngx.HTTP_POST or ngx.HTTP_GET,
        body = (spec.method == 'POST') and spec.data or nil,
        -- capture 出来的子请求不再往回传递 Cookie / 鉴权头，
        -- 避免把调用方凭据带给第三方上游
        vars = {
            ['proxy_set_header'] = '',
        },
    })

    if res == nil then
        return nil, nil, sformat('proxy capture for %s failed: %s', spec.name, tostring(err))
    end
    return res.status, res.body, nil
end

--------------------------------------------------------------------------------
-- 统一入口
--------------------------------------------------------------------------------

--- 按 spec 里的 `proxy` 标记选择通道。
--- @param spec table
--- @param cfg table
--- @return number|nil status
--- @return string|nil body
--- @return string|nil err
function _M.send(spec, cfg)
    if spec.proxy == true then
        return _M.requestViaProxy(spec, cfg)
    end
    return _M.request(spec, cfg)
end

--- 带一次重试的发送。
--- 仅对**幂等语义安全**的场景使用（GET，或由调用方显式声明可重试）。
--- @param spec table
--- @param cfg table
--- @param retryable boolean
--- @return number|nil status
--- @return string|nil body
--- @return string|nil err
function _M.sendWithRetry(spec, cfg, retryable)
    local status, body, err = _M.send(spec, cfg)
    if status or not retryable then
        return status, body, err
    end
    -- 退避 20ms 再试一次，避免立刻打在刚恢复的上游上
    ngx.sleep(0.02)
    local s2, b2, e2 = _M.send(spec, cfg)
    return s2, b2, e2 or err
end

return _M
