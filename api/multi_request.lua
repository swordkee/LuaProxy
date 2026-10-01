--- 通用反代通道：处理 `tcp[]` 批量请求。
---
--- 相对 2017 年 `api/multiRequest.lua` 的关键变化：
---   * **不再接受调用方传入的 host/port/protocol**，只接受白名单里的名字。
---     详见 `lib/upstream.lua` 文件头关于 SSRF 的说明。
---   * 返回值归一为 `env` 信封，与各厂商适配器同一套契约。
---   * 错误信息不再拼接内部主机名。

local util = require('lib.util')
local env = require('lib.envelope')
local http = require('lib.http')
local upstream = require('lib.upstream')

local type = type
local ipairs = ipairs
local sformat = string.format
local tinsert = table.insert
local m_floor = math.floor

local _M = {}

_M._VERSION = '2.0'

--- SOURCE 标签：响应中该组结果的键名。
_M.SOURCE = 'tcp'

--- 执行单个反代请求。
--- @param item table 调用方传入的 tcp[] 元素
--- @param cfg table
--- @return string source
--- @return table envelope
function _M.fetchOne(item, cfg)
    local start = ngx.now()
    local elapsed = function() return m_floor((ngx.now() - start) * 1000) end

    local spec, serr = upstream.resolve(item, cfg, cfg.max_body_bytes)
    if spec == nil then
        -- 白名单校验失败属于调用方错误 —— 403（未登记的 upstream 尤其要区分于 404）
        local code = env.CODES.FORBIDDEN
        if serr and serr:find('is not registered') then
            code = env.CODES.NOT_FOUND
        elseif serr and serr:find('upstream') then
            code = env.CODES.BAD_REQUEST
        end
        return _M.SOURCE, env.fail(code, serr, elapsed())
    end

    spec.proxy = (cfg.upstreams[spec.name] or {}).proxy == true

    local status, body, err = http.send(spec, cfg)

    if status == nil then
        if tostring(err):find('timed out') then
            return _M.SOURCE, env.fail(env.CODES.UPSTREAM_TIMEOUT,
                sformat('%s: %s', spec.name, tostring(err)), elapsed())
        end
        return _M.SOURCE, env.fail(env.CODES.UPSTREAM_UNAVAILABLE,
            sformat('%s: %s', spec.name, tostring(err)), elapsed())
    end

    if status ~= 200 then
        return _M.SOURCE, env.fail(env.CODES.NOT_FOUND,
            sformat('%s returned %d', spec.name, status), elapsed())
    end

    -- 上游返回的 JSON 原样透传给调用方（这正是「通用代理」的语义），
    -- 但仍归一成信封以保持响应结构一致。
    local ext = require('lib.ngx_ext')
    local payload, perr = ext.jsonDecode(body)
    if payload == nil then
        return _M.SOURCE, env.fail(env.CODES.UPSTREAM_BAD_BODY, perr, elapsed())
    end

    if type(payload) == 'table' and type(payload.result) == 'table' then
        return _M.SOURCE, env.hit(payload.result, elapsed())
    end

    -- 没有 result 字段：包成单元素数组，保持 result 恒为数组的契约
    return _M.SOURCE, env.hit({ payload }, elapsed())
end

--- 批量并发执行。每个 tcp[] 元素独立成一条记录，避免同 source 互相覆盖。
--- @param items table[] tcp[] 元素数组
--- @param cfg table
--- @param budgetMs number
--- @return table parts  { { source=, envelope= } }
function _M.fetchAll(items, cfg, budgetMs)
    local parts = {}
    if type(items) ~= 'table' or #items == 0 then
        return parts
    end

    -- 定时起点在函数入口取，而非模块级状态（模块状态会跨请求串味）
    local started = ngx.now()
    local threads = {}
    for i = 1, #items do
        threads[i] = ngx.thread.spawn(_M.fetchOne, items[i], cfg)
    end

    for i = 1, #threads do
        local remaining = budgetMs - (ngx.now() - started) * 1000
        if remaining <= 0 then
            ngx.thread.kill(threads[i])
            tinsert(parts, {
                source = _M.SOURCE,
                envelope = env.fail(env.CODES.UPSTREAM_TIMEOUT, 'budget exhausted', 0),
            })
        else
            local ok, source, envelope = ngx.thread.wait(threads[i], remaining)
            if ok then
                tinsert(parts, { source = source, envelope = envelope })
            elseif source == 'timeout' then
                ngx.thread.kill(threads[i])
                tinsert(parts, {
                    source = _M.SOURCE,
                    envelope = env.fail(env.CODES.UPSTREAM_TIMEOUT, 'budget exhausted', m_floor(remaining)),
                })
            else
                tinsert(parts, {
                    source = _M.SOURCE,
                    envelope = env.fail(env.CODES.INTERNAL, tostring(source), 0),
                })
            end
        end
    end

    return parts
end

return _M
