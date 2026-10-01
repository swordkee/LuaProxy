--- 适配器注册表：在 `init_by_lua` 阶段一次性完成 require 与契约校验。
---
--- ## 为什么要预建
--- 原版在**每个请求的每个数据源**上执行：
--- ```lua
--- -- t_thread.lua:14   spawn(require('api.' .. string.lower(v)).getInfo, args)
--- ```
--- 虽然 `require` 命中 `package.loaded` 时只是一次查表，但字符串拼接 + 表查找
--- 仍在热路径上。更重要的是：原版把「模块是否存在」「模块是否导出正确的方法」
--- 推迟到线上第一次请求才暴露。
---
--- 本模块在启动时完成：
---   1. `require` `conf.dmp` 中声明的每一个模块
---   2. 校验契约：`name` 字符串 + `fetch` 函数
---   3. 任一不合规即让 `nginx -s reload` 失败
---
--- ## 适配器契约
--- ```lua
--- -- api/example.lua
--- return {
---     name = 'example',                       -- 必须等于 conf.dmp 中的键名
---     fetch = function(self, params, budget_ms)
---         -- params:  调用方入参（含 key / mtype / tid ...）
---         -- 返回:    env.hit(tags, elapsed) 或 env.fail(code, detail)
---     end,
--- }
--- ```

local util = require('lib.util')

local type = type
local pairs = pairs
local ipairs = ipairs
local sformat = string.format
local tinsert = table.insert
local tconcat = table.concat

local _M = {}

_M._VERSION = '2.0'

--- 从 `conf.dmp` 构建注册表。
--- @param cfg table lib/config.load() 的结果
--- @return table|nil adapters  name -> adapter module
--- @return string|nil err
function _M.build(cfg)
    local adapters, problems = {}, {}

    for _, name in ipairs(cfg.dmp) do
        local modname = 'api.' .. name

        local ok, mod = pcall(require, modname)
        if not ok then
            tinsert(problems, sformat('%s: 加载失败 —— %s', modname, tostring(mod)))
        elseif type(mod) ~= 'table' then
            tinsert(problems, sformat('%s: 必须返回 table，实际返回 %s', modname, type(mod)))
        elseif type(mod.fetch) ~= 'function' then
            tinsert(problems, sformat('%s: 缺少 fetch(self, params, budget_ms) 方法', modname))
        elseif mod.name ~= nil and mod.name ~= name then
            tinsert(problems, sformat('%s: name 字段为 "%s"，应与 conf.dmp 中的键 "%s" 一致',
                modname, tostring(mod.name), name))
        else
            -- name 缺省时用 conf 里的键名补上
            if mod.name == nil then
                mod.name = name
            end
            adapters[name] = mod
        end
    end

    if #problems > 0 then
        return nil, '适配器注册失败:\n  ' .. tconcat(problems, '\n  ')
    end

    if next(adapters) == nil then
        return nil, 'conf.dmp 为空，没有任何可用的数据源'
    end

    return adapters
end

--- 返回注册表快照，供排障接口使用（不含函数体，避免泄漏）。
--- @param adapters table
--- @return table[]
function _M.describe(adapters)
    local out = {}
    if type(adapters) ~= 'table' then
        return out
    end
    for name, mod in pairs(adapters) do
        tinsert(out, {
            name = name,
            module = 'api.' .. name,
            version = mod.version or mod._VERSION or 'n/a',
        })
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

return _M
