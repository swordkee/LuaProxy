--- `log_by_lua` 入口：把排障摘要写入日志。
---
--- ## 相对 2017 年 `t_logger.lua` 修正的问题
---
--- ### 1) PII 无管控落盘（原版 t_logger.lua:4）
--- ```lua
--- ngx.log(ngx.WARN, ngx.ctx.msg)
--- -- 而 ngx.ctx.msg 在 api.lua:23 里是：
--- -- json_encode({ args = args, result = str, used = used })
--- ```
--- `args` 包含**完整的设备标识**（IMEI / IDFA / AndroidId / MAC / cookie），
--- `result` 是查询命中的人群包标签。两者以 WARN 级别写入 error log，
--- **无脱敏、无保留期、无访问控制** —— 叠加 access_log 即构成一条完整的
--- 设备指纹审计轨迹。
---
--- 本版：
---   * 只记录聚合后的**摘要**（命中了哪些数据源、各自耗时、状态码），
---     不记录原始入参与命中标签
---   * 写入前统一经 `util.redact` 脱敏、`util.truncate` 截断
---   * `log_request_summary = false` 时完全不记录
---
--- ### 2) `ngx.ctx.msg` 为 nil 时（日志阶段早于 content 阶段返回）
--- 原版 `ngx.log(ngx.WARN, nil)` 会打出 "nil"，没有意义。此处显式跳过。

local util = require('lib.util')
local ext = require('lib.ngx_ext')

local type = type
local ipairs = ipairs
local pairs = pairs
local sformat = string.format
local tconcat = table.concat
local tsort = table.sort

local cfg = _G.DMP and _G.DMP.cfg
if cfg == nil then
    -- init 未成功时不应在此处再抛错，交给 nginx 自身的 error_log 处理
    return
end

local function logToRsyslog(msg)
    local logger = require('resty.logger.socket')
    if not logger.initted() then
        local ok, err = logger.init({
            host = cfg.rsyslog.ip,
            port = cfg.rsyslog.port,
            sock_type = cfg.rsyslog.sock_type,
            flush_limit = cfg.rsyslog.flush_limit,
            drop_limit = cfg.rsyslog.drop_limit,
        })
        if not ok then
            ngx.log(ngx.ERR, 'cannot init rsyslog logger: ', tostring(err))
            return false
        end
    end

    local rfc5424 = require('resty.rfc5424')
    -- 原版用 ngx.var.pid 作为 MSGID / APP-NAME，既不是 pid 也不是 app 名，
    -- 会让 rsyslog 的字段解析全部错位
    local encoded = rfc5424.encode('LOCAL0', 'INFO', ngx.var.host or 'localhost',
        'luaproxy', 'api', msg)
    local _, err = logger.log(encoded)
    if err then
        ngx.log(ngx.ERR, 'rsyslog write failed: ', tostring(err))
        return false
    end
    return true
end

--------------------------------------------------------------------------------
-- 主流程
--------------------------------------------------------------------------------

if cfg.log_format ~= 'none' then
    local ctx = ngx.ctx

    -- content 阶段主动写入的摘要（api.lua 里 set）
    local summary = ctx.dmp_summary

    if summary ~= nil and type(summary) == 'table' then
        -- 稳定的字段顺序，便于日志检索与告警规则匹配
        local sources = {}
        for name in pairs(summary.sources or {}) do
            sources[#sources + 1] = name
        end
        tsort(sources)

        local codes = {}
        for _, name in ipairs(sources) do
            local env = summary.sources[name]
            codes[#codes + 1] = sformat('%s=%d/%dms', name, env.code, env.elapsed or 0)
        end

        local line = sformat('dmp code=%s elapsed=%dms sources=[%s] req_id=%s',
            tostring(summary.code or 0),
            summary.elapsed or 0,
            tconcat(codes, ' '),
            tostring(summary.req_id or '-'))

        -- 双重保险：即便上游代码误把敏感字段塞进 summary，这里仍会脱敏
        line = util.redact(util.truncate(line, 1024))

        if cfg.log_format == 'rsyslog' then
            logToRsyslog(line)
        else
            ngx.log(ngx.WARN, line)
        end
    elseif type(ctx.dmp_error) == 'string' then
        -- content 阶段失败（如入参非法）时只记脱敏后的错误，不记入参
        local line = util.redact(util.truncate('dmp error=' .. ctx.dmp_error, 512))
        if cfg.log_format == 'rsyslog' then
            logToRsyslog(line)
        else
            ngx.log(ngx.ERR, line)
        end
    end

    -- 兼容旧调用方：新代码应写 ngx.ctx.dmp_summary，旧代码可能仍在写 ngx.ctx.msg。
    -- 这里**不直接落 ngx.ctx.msg**（那正是原版泄漏 PII 的通道），
    -- 只在显式开启 debug 时输出脱敏后的内容。
    if cfg.DEBUG and type(ctx.msg) == 'string' then
        ngx.log(ngx.NOTICE, 'dmp debug: ', util.redact(util.truncate(ctx.msg, 2048)))
    end
end
