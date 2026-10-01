--- 主入口（`content_by_lua`）：聚合查询。
---
--- 用法：
--- ```bash
--- # 查 example 数据源
--- curl -s 'http://127.0.0.1:8083/api' -d '{
---   "dmp": "example",
---   "key": "8D6A13B7FE90BBE6079AE1D91159E387",
---   "mtype": "imei_md5",
---   "tid": "1001,1002"
--- }'
---
--- # 多数据源 + 通用反代（tcp 的 host 由服务端白名单决定，调用方只给名字）
--- curl -s 'http://127.0.0.1:8083/api' -d '{
---   "dmp": "example",
---   "key": "...",
---   "tcp": [{"upstream": "partner", "path": "/v1/query?a=1", "method": "GET"}]
--- }'
--- ```

local orchestrator = require('lib.orchestrator')
local multiRequest = require('api.multi_request')
local envelope = require('lib.envelope')
local ext = require('lib.ngx_ext')
local util = require('lib.util')

local type = type
local ipairs = ipairs
local pairs = pairs
local tinsert = table.insert

local CODES = envelope.CODES

local function run()
    local DMP = _G.DMP
    if DMP == nil or DMP.cfg == nil then
        return ext.replyError(500, 'service not initialised')
    end
    local cfg = DMP.cfg

    -- ---- 方法校验 ----
    local method = ngx.var.request_method
    if method ~= 'POST' then
        ngx.header['Allow'] = 'POST'
        return ext.replyError(CODES.METHOD_NOT_ALLOWED, 'only POST is accepted')
    end

    -- ---- 解析入参 ----
    local args, err = ext.readBody(cfg.max_body_bytes)
    if args == nil then
        local status = CODES.BAD_REQUEST
        if tostring(err):find('too large') then
            status = CODES.PAYLOAD_TOO_LARGE
        end
        -- 只把**脱敏后的错误原因**交给日志，绝不记录原始入参
        ngx.ctx.dmp_error = util.truncate(tostring(err), 300)
        return ext.replyError(status, err)
    end

    -- ---- 聚合查询 ----
    local grouped, meta = orchestrator.run(args, cfg, DMP.adapters)

    -- ---- 通用反代通道 ----
    -- 独立于 dmp 白名单：它访问的是 system.upstreams 里登记的目标，
    -- 与「哪些数据源已实现」是两回事。
    if not util.isBlank(args.tcp) then
        local specs, rejected = orchestrator.buildTcpSpecs(args, cfg)
        meta.rejected = rejected
        if #specs > 0 then
            local parts = multiRequest.fetchAll(specs, cfg, cfg.source_budget_ms)
            for _, p in ipairs(parts) do
                local bucket = grouped[p.source]
                if bucket == nil then
                    grouped[p.source] = p.envelope
                else
                    -- 同一 source 的多次结果做数组合并（追加，不覆盖）
                    local merged = util.deepMerge({}, { bucket, p.envelope })
                    -- deepMerge 会把两个信封当普通表合，需要重新挑出 result
                    if type(merged) == 'table' then
                        if bucket.code == CODES.HIT and p.envelope.code == CODES.HIT then
                            local acc = {}
                            for _, item in ipairs(bucket.result) do tinsert(acc, item) end
                            for _, item in ipairs(p.envelope.result) do tinsert(acc, item) end
                            acc = util.unique(acc)
                            grouped[p.source] = envelope.hit(acc, math.max(bucket.elapsed or 0, p.envelope.elapsed or 0))
                        elseif p.envelope.code == CODES.HIT then
                            grouped[p.source] = p.envelope
                        end
                    end
                end
            end
        end
    end

    local body = orchestrator.toResponse(grouped, meta)

    -- ---- 排障摘要（供 lib/logger.lua 落日志）----
    -- 原版把**完整请求参数与查询结果**（IMEI/IDFA/cookie 等设备指纹）以 WARN
    -- 级别写进 error log，无脱敏无保留期。此处只记录聚合后的摘要：
    -- 命中了哪些数据源、各自状态码与耗时。入参与命中标签一概不记录。
    ngx.ctx.dmp_summary = {
        code = body.code,
        elapsed = body.elapsed,
        sources = grouped,
        req_id = ngx.var.request_id,
    }

    -- ---- HTTP 状态码 ----
    -- 原版所有分支都返回 200，错误只写在 body 里，调用方无法靠状态码判断成败。
    local httpStatus = 200
    if body.code == CODES.BAD_REQUEST or body.code == CODES.PAYLOAD_TOO_LARGE then
        httpStatus = 400
    elseif body.code == CODES.FORBIDDEN then
        httpStatus = 403
    elseif body.code == CODES.UPSTREAM_UNAVAILABLE or body.code == CODES.INTERNAL then
        httpStatus = 502
    end

    return ext.reply(httpStatus, body)
end

return run()
