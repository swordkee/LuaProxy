--- `init_by_lua` 入口：一次性完成配置校验、适配器注册、常量预计算。
---
--- ## 相对 2017 年 `init.lua` 的变化
--- 原版在 init 阶段向全局注入 `isEmpty` / `on` / `pr` / `json_decode` 等函数，
--- 并**猴补 `string` 与 `table` 的方法**：
--- ```lua
--- string.split = function(...) end
--- string.trim  = function(...) end
--- table.len / table.merge / table.unique / table.findkeys / table.invert
--- ```
--- 全局污染会与其他库命名冲突、干扰基于 `pairs` 的工具链，
--- 也让人无法判断某个函数究竟来自哪里。
--- 本版本把它们收进 `lib/util.lua` 显式导出，不再猴补标准库。
---
--- 另外原版**没有任何配置校验**：`conf/*.lua` 里 key 拼错要等到线上第一次
--- 请求命中该分支才会以 `attempt to index a nil value` 暴露。
--- 本版本在启动期一次性校验，任一不合规即让 `nginx -s reload` 失败。

local configMod = require('lib.config')
local dispatch = require('lib.dispatch')
local upstream = require('lib.upstream')
local ext = require('lib.ngx_ext')
local util = require('lib.util')

local type = type
local pairs = pairs
local ipairs = ipairs
local sformat = string.format
local tconcat = table.concat
local tsort = table.sort

--- 启动期构建的全局上下文。显式挂在 `_G.DMP` 下，让「谁定义了什么」一目了然。
local DMP = {
    cfg = nil,
    adapters = nil,
    warnings = nil,
    bootMs = nil,
}

_G.DMP = DMP

--- 校验配置。任一环节失败直接 error —— 配置错误应当在启动时暴露，
--- 而不是运行中静默降级。
local cfg, cfgErr = configMod.load()
if cfg == nil then
    error('[dmp] 配置校验失败:\n' .. tostring(cfgErr), 0)
end
DMP.cfg = cfg

local adapters, adErr = dispatch.build(cfg)
if adapters == nil then
    error('[dmp] ' .. tostring(adErr), 0)
end
DMP.adapters = adapters

-- 白名单自检：只告警，不阻断启动
DMP.warnings = upstream.selfCheck(cfg)

-- 把 cfg 注入需要它的适配器，避免每次 fetch 都 require conf
for _, mod in pairs(adapters) do
    if type(mod.setConfig) == 'function' then
        mod.setConfig(cfg)
    end
end

DMP.bootMs = ngx.now() * 1000

--------------------------------------------------------------------------------
-- 启动日志（不含任何敏感配置）
--------------------------------------------------------------------------------

local upstreamNames = {}
for name in pairs(cfg.upstreams) do
    upstreamNames[#upstreamNames + 1] = name
end
tsort(upstreamNames)

ngx.log(ngx.NOTICE, sformat(
    '[dmp] boot ok: sources=[%s] upstreams=[%s] ttl=%dms budget=%d/%dms warnings=%d',
    tconcat(cfg.dmp, ','),
    tconcat(upstreamNames, ','),
    cfg.dict_ttl_ms,
    cfg.source_budget_ms,
    cfg.request_budget_ms,
    #DMP.warnings
))

for _, w in ipairs(DMP.warnings) do
    ngx.log(ngx.WARN, '[dmp] config warning: ', w)
end

--------------------------------------------------------------------------------
-- 兼容层（deprecated）
--------------------------------------------------------------------------------

--- 保留原版这几个全局函数名，内部改为薄封装，让既有调用方不必立刻改。
--- **新代码请直接 `require('lib.util')` / `require('lib.ngx_ext')`。**

--- @deprecated 请改用 `util.isBlank`
_G.isEmpty = util.isBlank

--- @deprecated 普通 `if` 即可，无需三元封装
_G.on = function(cond, a, b)
    if cond then
        return a
    end
    return b
end

--- @deprecated 请改用 `ext.jsonDecode`
_G.json_decode = ext.jsonDecode

--- @deprecated 请改用 `ext.jsonEncode`
_G.json_encode = ext.jsonEncode

--- @deprecated 请改用 `ext.newIdCookie`
_G.createIdCookie = ext.newIdCookie
