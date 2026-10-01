--- `init_worker_by_lua` 入口：每个 worker 启动时执行一次。
---
--- ## 相对 2017 年 `init_worker.lua` 修正的问题
---
--- ### 1) 原版在公开精简仓里**根本启动不了**
--- ```lua
--- -- init_worker.lua:2 (公开版)
--- local GT = require("api.gt")
--- ```
--- `api/gt.lua` 已随 12 个厂商适配器一起从公开仓删除，
--- 而这个 `require` 位于 `init_worker_by_lua` —— nginx 的 worker 初始化阶段。
--- 结果是 **require 失败 → 所有 worker 起不来**。
--- 本版本不再在 init 阶段 require 任何具体适配器。
---
--- ### 2) 定时器只存在于公开版，`api.lua` 侧完全没有刷新逻辑
--- 本版本把 token 刷新做成一个**可选的、按需注册**的机制：
--- 只有在 `conf.system.refreshers` 中显式声明的数据源才会被定时刷新。
---
--- ### 3) `ngx.timer.at` 递归自调度 → 改用 `ngx.timer.every`
--- 原版靠在回调里再次 `ngx.timer.at` 实现周期。
--- `ngx.timer.every` 是为此场景提供的原生 API，语义更清晰且失败可见。

local ext = require('lib.ngx_ext')

local type = type
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local sformat = string.format
local tsort = table.sort
local m_floor = math.floor

local cfg = _G.DMP and _G.DMP.cfg
if cfg == nil then
    ngx.log(ngx.ERR, '[dmp] init_worker 运行时 DMP 未初始化，init.lua 是否加载成功？')
    return
end

-- 进程级随机源只播种一次。原版在每次生成 id 时都重播种子，
-- 而 ngx.now() 是毫秒精度 —— 同一毫秒内的请求会得到相同的随机序列。
ext.seedWorker()

--------------------------------------------------------------------------------
-- 周期性刷新
--------------------------------------------------------------------------------

--- @type table<string, fun()>
local refreshers = {}

for _, name in ipairs(cfg.refreshers or {}) do
    local modName = 'api.' .. name
    local ok, mod = pcall(require, modName)
    if not ok then
        ngx.log(ngx.ERR, sformat('[dmp] skip refresher %s: %s', modName, tostring(mod)))
    elseif type(mod) ~= 'table' or type(mod.refresh) ~= 'function' then
        ngx.log(ngx.ERR, sformat('[dmp] skip refresher %s: 缺少 refresh() 方法', modName))
    else
        refreshers[name] = mod.refresh
        ngx.log(ngx.NOTICE, sformat('[dmp] refresher registered: %s', modName))
    end
end

--- @param premature boolean  ngx.timer 的提前终止标记
local function tick(premature)
    if premature then
        return
    end

    local names = {}
    for name in pairs(refreshers) do
        names[#names + 1] = name
    end
    tsort(names)

    for _, name in ipairs(names) do
        local ok, err = pcall(refreshers[name])
        if not ok then
            -- 刷新失败只告警：不应让定时器退出，否则该数据源会永久失去刷新
            ngx.log(ngx.WARN, sformat('[dmp] refresher %s failed: %s', name, tostring(err)))
        end
    end
end

if next(refreshers) ~= nil then
    local intervalMs = cfg.refresh_interval_ms or 600000
    -- 每个 worker 错峰启动，避免 N 个 worker 同时打同一个厂商接口。
    -- 原版所有 worker 都在 conf.delay(7s) 后精确同时执行。
    -- 注意：Lua 5.1 没有 `//` 运算符，必须用 math.floor。
    local slot = m_floor(intervalMs / 5)
    if slot < 1 then
        slot = 1
    end
    local jitterMs = (ngx.worker.pid() * 1000) % slot

    local ok, err = ngx.timer.at(jitterMs, function(premature)
        if not premature then
            local eok, eerr = ngx.timer.every(intervalMs, tick)
            if not eok then
                ngx.log(ngx.ERR, sformat('[dmp] cannot start periodic timer: %s', tostring(eerr)))
            end
        end
    end)
    if not ok then
        ngx.log(ngx.ERR, sformat('[dmp] cannot schedule initial timer: %s', tostring(err)))
    end
end

--------------------------------------------------------------------------------
-- 缓存预热
--------------------------------------------------------------------------------

--- 只在每个 worker 的首次启动时预热一次。
--- 原版由所有 worker 每 7 秒各做一次全量扫描 —— N 个 worker 就是 N 倍重复 IO。
if cfg.warmup_on_boot == true then
    local cache = require('lib.cache')
    for _, name in ipairs(cfg.warmup_sources or cfg.dmp) do
        local ok, stats = pcall(cache.warmup, name, cfg)
        if ok and type(stats) == 'table' then
            ngx.log(ngx.NOTICE, sformat(
                '[dmp] warmup %s: scanned=%d loaded=%d skipped=%d',
                name, stats.scanned or 0, stats.loaded or 0, stats.skipped or 0))
        elseif not ok then
            ngx.log(ngx.WARN, sformat('[dmp] warmup %s failed: %s', name, tostring(stats)))
        end
    end
end

ngx.log(ngx.NOTICE, sformat('[dmp] worker %d ready (pid=%d)',
    ngx.worker.id(), ngx.worker.pid()))
