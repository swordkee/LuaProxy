--- 协程编排：把 N 个数据源的查询并发扇出、限时收割、归并。
---
--- ## 相对 2017 年 `t_thread.lua` 修正的三件事
---
--- ### 1) 结果互相覆盖（原版 t_thread.lua:53-65）
--- 原版用 `table.unique` + `table.findkeys` 配 `table.merge` 来合并同 source 的多次结果，
--- 而 `table.merge` 合并**数组**时走的是 `else a[k] = v` 分支 —— 下标直接覆盖。
--- 配合 `api/nad.lua` 与 `api/ad.lua` 同为 `source = "ad"`，一次 `dmp=ad,nad` 请求
--- 就会丢掉一半结果，且客户端完全无感知。现改为 `util.groupBy` + `util.deepMerge`，
--- 数组合并语义为**追加**，且时间复杂度从 O(n²) 降到 O(n)。
---
--- ### 2) 超时判定整段被注释（原版 t_thread.lua:37-44）
--- 原代码里 `conf.TIMEOUT` 的超时循环被完整注释掉，`TIMEOUT` 成了死配置，
--- 一个卡住的上游会让整个请求挂到 nginx 默认超时（60s）。
--- 现使用 `ngx.thread.wait(thread, timeout)` + `ngx.thread.kill(thread)`：
--- 单源超预算即记 504 并继续，不拖累其他数据源。
---
--- ### 3) 协程错误被静默吞掉（原版 t_thread.lua:46-51）
--- 原版 `local ok, info, source, used = ngx.thread.wait(threads[i])`，
--- 协程内抛异常时 `ok` 为 nil、`info` 是错误串，于是该数据源**直接从结果里消失**，
--- 既不报错也不留痕。现改为在被调度函数内部 `pcall`，异常统一转成
--- 500 信封并带 `trace` 摘要，调用方与监控都能看到。

local util = require('lib.util')
local env = require('lib.envelope')

local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local sformat = string.format
local tinsert = table.insert
local tconcat = table.concat

local m_floor = math.floor

local _M = {}

_M._VERSION = '2.0'

--------------------------------------------------------------------------------
-- 调度包装
--------------------------------------------------------------------------------

--- 在独立协程里执行一个数据源，把任何异常都收敛成信封。
--- @param name string 数据源名
--- @param adapter table 已注册的适配器
--- @param params any 该数据源的入参
--- @param budgetMs number 该数据源的时间预算
--- @return string source
--- @return table envelope
local function runOne(name, adapter, params, budgetMs)
    local start = ngx.now()

    local ok, res = pcall(adapter.fetch, adapter, params, budgetMs)

    if not ok then
        -- 适配器抛异常：不影响其他数据源，但要留下可定位的痕迹
        local trace = tostring(res):gsub('\n', ' | ')
        ngx.log(ngx.ERR, sformat('[dmp] adapter "%s" raised: %s', name, trace))
        return name, env.fail(env.CODES.INTERNAL, util.truncate(trace, 150), m_floor((ngx.now() - start) * 1000))
    end

    if type(res) ~= 'table' or res.code == nil then
        return name, env.fromLegacy(res, m_floor((ngx.now() - start) * 1000))
    end

    res.elapsed = res.elapsed or m_floor((ngx.now() - start) * 1000)
    return name, res
end

--------------------------------------------------------------------------------
-- 计划构建
--------------------------------------------------------------------------------

--- 根据入参决定要查哪些数据源。
---
--- 支持两种形态：
---   * `dmp = "mz,gt"`                    —— 逗号分隔的名字列表，用 conf 中的默认 vendor 配置
---   * `mz = {...}, gt = {...}`           —— 每源自带参数
---
--- 未登记在 `cfg.dmp` 中的键会被忽略（原版靠 `in_table` 过滤，保留该行为，
--- 它同时也是阻断 `require` 路径穿越的一道防线）。
---
--- @param args table
--- @param cfg table
--- @param registry table lib/dispatch 的 adapters 表
--- @return table[] plans  { { name=, adapter=, params= } }
--- @return string[] unknown 白名单外被忽略的键
local function buildPlans(args, cfg, registry)
    local plans, unknown = {}, {}
    if type(args) ~= 'table' then
        return plans, unknown
    end

    -- 形态一：dmp = "a,b"
    local dmp = args.dmp
    if type(dmp) == 'string' and not util.isBlank(dmp) then
        for _, name in ipairs(util.splitList(dmp, ',')) do
            if util.contains(name, cfg.dmp) then
                if registry[name] then
                    -- 每个适配器拿到独立的浅拷贝：
                    -- 原版直接把同一个 args 表传给所有协程，任一适配器写了一个字段
                    -- 就会污染其他数据源的入参。
                    local shared = {}
                    for k, v in pairs(args) do
                        shared[k] = v
                    end
                    tinsert(plans, { name = name, adapter = registry[name], params = shared })
                else
                    tinsert(unknown, name)
                end
            else
                tinsert(unknown, name)
            end
        end
        return plans, unknown
    end

    -- 形态二：每个 key 一个数据源
    for key, value in pairs(args) do
        if key ~= 'tcp' and key ~= 'callBack' and key ~= 'mtype' then
            if util.contains(key, cfg.dmp) then
                if registry[key] then
                    local params = value
                    -- 允许 { key=..., ... } 形式
                    if type(value) == 'table' then
                        params = value
                    else
                        params = { key = value }
                    end
                    tinsert(plans, { name = key, adapter = registry[key], params = params })
                else
                    tinsert(unknown, key)
                end
            end
        end
    end
    return plans, unknown
end

--- 解析批量 tcp[] 请求。
--- @param args table
--- @param cfg table
--- @return table[] specs
--- @return table[] rejected { { index=, err= } }
function _M.buildTcpSpecs(args, cfg)
    local specs, rejected = {}, {}
    local list = args and args.tcp
    if type(list) ~= 'table' then
        return specs, rejected
    end
    local upstream = require('lib.upstream')
    for i, item in ipairs(list) do
        local spec, err = upstream.resolve(item, cfg, cfg.max_body_bytes)
        if spec == nil then
            tinsert(rejected, { index = i, err = err })
        else
            spec.proxy = (cfg.upstreams[item.upstream] or {}).proxy == true
            tinsert(specs, spec)
        end
    end
    return specs, rejected
end

--------------------------------------------------------------------------------
-- 主流程
--------------------------------------------------------------------------------

--- 执行一次聚合查询。
---
--- @param args table 调用方入参（已解析）
--- @param cfg table   lib/config.load() 的结果
--- @param registry table lib/dispatch 的 adapters
--- @return table grouped   { source -> envelope }
--- @return table meta      { elapsed=, unknown=, timed_out=, failed=, rejected= }
function _M.run(args, cfg, registry)
    local started = ngx.now()
    local grouped, meta = {}, {
        elapsed = 0,
        unknown = {},
        timed_out = {},
        failed = {},
        rejected = {},
    }

    local plans, unknown = buildPlans(args, cfg, registry)
    meta.unknown = unknown

    -- ---- 并发扇出 ----
    local spawn = ngx.thread.spawn
    local wait = ngx.thread.wait
    local kill = ngx.thread.kill

    local threads = {}
    for i = 1, #plans do
        local p = plans[i]
        tinsert(threads, {
            name = p.name,
            thread = spawn(runOne, p.name, p.adapter, p.params, cfg.source_budget_ms),
        })
    end

    -- ---- 限时收割 ----
    for i = 1, #threads do
        local slot = threads[i]
        -- 全局预算耗尽时不再等待剩余数据源，直接判超时
        local left = cfg.request_budget_ms - (ngx.now() - started) * 1000
        local budget = left < cfg.source_budget_ms and left or cfg.source_budget_ms
        if budget <= 0 then
            kill(slot.thread)
            tinsert(meta.timed_out, slot.name)
            grouped[slot.name] = env.fail(env.CODES.UPSTREAM_TIMEOUT, 'request budget exhausted', 0)
        else
            local ok, source, envelope = wait(slot.thread, budget)
            if ok then
                grouped[source] = envelope
                if envelope.code >= 500 then
                    tinsert(meta.failed, source)
                end
            elseif source == 'timeout' then
                -- ngx.thread.wait 的超时返回值固定为 (nil, "timeout")
                kill(slot.thread)
                tinsert(meta.timed_out, slot.name)
                grouped[slot.name] = env.fail(
                    env.CODES.UPSTREAM_TIMEOUT,
                    sformat('exceeded %sms budget', m_floor(budget)),
                    m_floor(budget))
            else
                -- runOne 内部已 pcall，正常不会走到这里；
                -- 万一走到说明协程体本身出了致命错误（例如 OOM），显式记 500 而不是丢弃
                grouped[slot.name] = env.fail(
                    env.CODES.INTERNAL,
                    'worker died: ' .. util.truncate(tostring(source), 120),
                    m_floor((ngx.now() - started) * 1000))
                tinsert(meta.failed, slot.name)
            end
        end
    end

    meta.elapsed = m_floor((ngx.now() - started) * 1000)
    return grouped, meta
end

--- 归并多个查询的结果。
---
--- 同一 source 出现多次时，**数组追加**而非覆盖（见文件头 §1）。
--- 原版这里用 `unique` + `findkeys` + `table.merge`，是 O(n²) 且会丢数据。
---
--- @param parts table[] 形如 { { source=, envelope= } }
--- @return table grouped
--- @return string[] order 稳定的 source 顺序，便于响应可复现
function _M.merge(parts)
    local keys, values = {}, {}
    for i = 1, #parts do
        local p = parts[i]
        if p and p.source then
            tinsert(keys, p.source)
            tinsert(values, p.envelope)
        end
    end
    local grouped, order = util.groupBy(keys, values, { concat_arrays = true })
    return grouped, order
end

--- 把 orchestrator 的产物整理成对外响应体。
--- @param grouped table
--- @param meta table
--- @return table
function _M.toResponse(grouped, meta)
    local hits, codes = env.flatten(grouped)

    local out = {
        sources = {},
        elapsed = meta and meta.elapsed or 0,
    }

    -- 按 source 列出命中的标签
    for source, tags in pairs(hits) do
        if #tags > 0 then
            out.sources[source] = tags
        end
    end

    -- 便于调用方一眼判断整体成败的聚合状态
    local anyHit, anyHardFail = false, false
    for source, envelope in pairs(grouped) do
        if envelope.code == env.CODES.HIT then
            anyHit = true
        elseif envelope.code >= 500 then
            anyHardFail = true
        end
    end
    out.code = anyHit and env.CODES.HIT
        or (anyHardFail and env.CODES.UPSTREAM_UNAVAILABLE or env.CODES.NO_MATCH)
    out.codes = codes

    -- meta 各字段可能缺省（调用方只传部分诊断信息），统一取局部变量后再用
    local unknown = (meta and meta.unknown) or {}
    local timedOut = (meta and meta.timed_out) or {}
    local rejected = (meta and meta.rejected) or {}

    if #unknown > 0 or #timedOut > 0 or #rejected > 0 then
        local diag = {}
        if #unknown > 0 then
            tinsert(diag, 'unknown=' .. tconcat(unknown, ','))
        end
        if #timedOut > 0 then
            tinsert(diag, 'timeout=' .. tconcat(timedOut, ','))
        end
        if #rejected > 0 then
            local parts = {}
            for _, r in ipairs(rejected) do
                tinsert(parts, sformat('#%d:%s', r.index, r.err))
            end
            tinsert(diag, 'rejected=' .. tconcat(parts, ';'))
        end
        out.diag = tconcat(diag, ' ')
    end

    return out
end

return _M
