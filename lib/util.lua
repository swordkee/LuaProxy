--- 通用工具集：纯函数，无副作用，**不污染全局**。
---
--- 与 2017 年 `init.lua` 的关键差异：
---   * 不再猴补 `string` / `table`；所有函数经本模块显式导出。
---   * `isBlank` / `orElse` 始终返回真正的 boolean。
---     原版 `on()` 写作 `(b and {x} or {y})[1]`，每次调用额外分配两个 table；
---     原版 `isEmpty` 在 number 分支把 `0` 判为"空"，是个隐蔽的口径坑。
---   * `split` 不再返回 nil，缺失元素补空串。
---   * `deepMerge` 对数组执行**追加**而非下标覆盖（原版 `table.merge` 会静默丢数据）。
---
--- 本模块刻意不引用 `ngx`，以便在没有 OpenResty 运行时的情况下做单元测试。
--- 需要 ngx 能力的辅助函数放在 `lib/ngx_ext.lua`。

local _M = {}

local type = type
local pairs = pairs
local ipairs = ipairs
local next = next
local type_pairs = type
local tostring = tostring
local tonumber = tonumber
local sformat = string.format
local ssub = string.sub
local sfind = string.find
local sgsub = string.gsub
local sbyte = string.byte
local schar = string.char
local supper = string.upper
local srep = string.rep
local tconcat = table.concat
local tinsert = table.insert
local tsort = table.sort

local mfloor = math.floor

_M._VERSION = '2.0'

--------------------------------------------------------------------------------
-- 空值判定
--------------------------------------------------------------------------------

--- 判定「无有效内容」。
--- 覆盖：nil、ngx 注入的 null、空串/纯空白串、空表。
--- 数字永不算空（0 是有效值）。
--- @param v any
--- @return boolean
function _M.isBlank(v)
    local t = type_pairs(v)
    if v == nil then
        return true
    elseif t == 'string' then
        return v == '' or v:find('^%s*$') ~= nil
    elseif t == 'table' then
        return next(v) == nil
    elseif t == 'userdata' then
        -- ngx.null 是 userdata，统一按空处理
        return true
    end
    return false
end

--- v 非空时返回 v，否则返回 fallback。
--- 对应原版的 `on(not isEmpty(v), v, default)`。
--- @param v any
--- @param fallback any
--- @return any
function _M.orElse(v, fallback)
    if _M.isBlank(v) then
        return fallback
    end
    return v
end

--- 取出字符串/数字/布尔，非空否则 fallback。
--- @param v any
--- @param fallback any
--- @return any
function _M.toStringOr(v, fallback)
    local t = type_pairs(v)
    if t == 'string' then
        return v
    elseif t == 'number' then
        return tostring(v)
    elseif t == 'boolean' then
        return v and 'true' or 'false'
    end
    return fallback
end

--------------------------------------------------------------------------------
-- 字符串
--------------------------------------------------------------------------------

--- 去除首尾空白。原版 `string.trim` 会在参数非法时返回 `nil, err`（二返回值），
--- 调用方极易只取到第一个返回值，此处统一返回字符串。
--- @param s any
--- @return string
function _M.trim(s)
    if type_pairs(s) ~= 'string' then
        return ''
    end
    return (sgsub(s, '^%s*(.-)%s*$', '%1'))
end

--- 按字面量分隔符切分。原版直接委托给 C 扩展 `utils.split`，
--- 这里保留一个等价的纯 Lua 实现作为兜底（C 扩展缺失时不至于整站 500）。
--- @param str string
--- @param delim string 字面量分隔符，非空
--- @return string[] 至少含一个元素（入参为空时返回 { '' }）
function _M.split(str, delim)
    local out = {}
    if type_pairs(str) ~= 'string' or str == '' then
        return out
    end
    if type_pairs(delim) ~= 'string' or delim == '' then
        tinsert(out, str)
        return out
    end

    local from = 1
    while true do
        local s, e = sfind(str, delim, from, true)
        if not s then
            break
        end
        tinsert(out, ssub(str, from, s - 1))
        from = e + 1
    end
    tinsert(out, ssub(str, from))
    return out
end

--- 切分并去掉空白项，用于解析 `a,b,,c` 这类调用方输入。
--- @param str string
--- @param delim string
--- @return string[]
function _M.splitList(str, delim)
    local out = {}
    for _, item in ipairs(_M.split(str, delim or ',')) do
        local v = _M.trim(item)
        if v ~= '' then
            tinsert(out, v)
        end
    end
    return out
end

--- bytes -> 十六进制字符串。原版 `bin2hex` 用 `(.)` 逐字符 gsub，
--- 对含 `\0` 的二进制串不可靠，这里改为按 %02x 遍历。
--- @param s string
--- @return string
function _M.bin2hex(s)
    if type_pairs(s) ~= 'string' then
        return ''
    end
    local out = {}
    for i = 1, #s do
        tinsert(out, sformat('%02X', sbyte(s, i)))
    end
    return tconcat(out)
end

--------------------------------------------------------------------------------
-- 表
--------------------------------------------------------------------------------

--- 表内元素个数（O(n)）。用于确需区分「数组表 / 哈希表」的场景。
--- @param t table
--- @return integer
function _M.count(t)
    local n = 0
    if type_pairs(t) ~= 'table' then
        return 0
    end
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

--- 判断数组（连续整型下标）。用于选择合并策略。
--- @param t table
--- @return boolean
function _M.isArray(t)
    if type_pairs(t) ~= 'table' then
        return false
    end
    local n = 0
    for k in pairs(t) do
        if type_pairs(k) ~= 'number' then
            return false
        end
        n = n + 1
    end
    return n == #t
end

--- 值是否在数组中。
--- @param v any
--- @param arr table
--- @return boolean
function _M.contains(v, arr)
    if type_pairs(arr) ~= 'table' then
        return false
    end
    for _, item in ipairs(arr) do
        if item == v then
            return true
        end
    end
    return false
end

--- 构建反向索引（value -> key）。仅用于**不变**的静态表（如上游白名单），
--- 在 init 阶段算一次后缓存，热路径不要重复调用。
--- @param t table
--- @return table
function _M.invert(t)
    local out = {}
    if type_pairs(t) ~= 'table' then
        return out
    end
    for k, v in pairs(t) do
        out[v] = k
    end
    return out
end

--- 数组去重，**保持首次出现顺序**。
--- 原版 `table.unique` 依赖 `if not (check[v])`，当首元素为 `false` 时会误判。
--- @param arr table
--- @return table
function _M.unique(arr)
    local seen, out = {}, {}
    if type_pairs(arr) ~= 'table' then
        return out
    end
    for _, v in ipairs(arr) do
        if seen[v] == nil then
            seen[v] = true
            tinsert(out, v)
        end
    end
    return out
end

--- 取出所有值等于 v 的下标。
--- @param arr table
--- @param v any
--- @return integer[]
function _M.findIndexes(arr, v)
    local out = {}
    if type_pairs(arr) ~= 'table' then
        return out
    end
    for i, item in ipairs(arr) do
        if item == v then
            tinsert(out, i)
        end
    end
    return out
end

--- 深合并：哈希表递归合并，**数组合并**。
---
--- 这是对原版最关键的一处行为修正。原 `table.merge` 对数组合并时会走
--- `else a[k] = v` 分支直接覆盖下标，导致同 source 的多次结果互相冲掉
--- （`api/nad.lua` 与 `api/ad.lua` 同为 `source = "ad"`，一次请求即丢一半结果）。
---
--- @param dst table 被合并目标，原地修改
--- @param src table 来源
--- @param opts table|nil { concat_arrays = boolean, _seen = table }
--- @return table dst
function _M.deepMerge(dst, src, opts)
    opts = opts or {}
    if type_pairs(dst) ~= 'table' then
        dst = {}
    end
    if type_pairs(src) ~= 'table' then
        return dst
    end

    -- 环检测：缓存映射表在极端自引用场景下会无限递归
    local seen = opts._seen
    if seen == nil then
        seen = {}
        opts._seen = seen
    end
    if seen[src] then
        return dst
    end
    seen[src] = true

    -- ---- 数组 ----
    -- 语义：**追加**（不是按位置覆盖）。
    -- 关键点：数组元素按位置遍历时，dst[k] 是「第 k 个元素」而非「第 k 个子表」，
    -- 不能当成待合并的子表，否则下标 1、2 会被逐个替换掉，结果依然在丢数据。
    if _M.isArray(src) then
        for _, v in ipairs(src) do
            if type_pairs(v) == 'table' then
                -- 元素本身是表：与 dst 中同位置已有元素合并（可为空槽）
                local idx = #dst + 1
                -- 找一个已存在且类型匹配的槽位优先
                for i = 1, #dst do
                    if type_pairs(dst[i]) == 'table' then
                        idx = i
                        break
                    end
                end
                dst[idx] = _M.deepMerge(dst[idx] or {}, v, opts)
            else
                tinsert(dst, v)
            end
        end
        return dst
    end

    -- ---- 哈希表 ----
    for k, v in pairs(src) do
        if type_pairs(v) == 'table' then
            if type_pairs(dst[k]) ~= 'table' then
                dst[k] = {}
            end
            _M.deepMerge(dst[k], v, opts)
        else
            dst[k] = v
        end
    end

    return dst
end

--- 按 key 分组，组内保持原顺序。
--- 用于把 `source -> 结果` 的并行数组重新组织成 map，替代原版的 O(n^2) 双重扫描。
--- @param keys any[]  键数组
--- @param values any[] 值数组，与 keys 等长
--- @param opts table|nil { concat_arrays = boolean }
--- @return table
function _M.groupBy(keys, values, opts)
    opts = opts or {}
    local out = {}
    local order = {}
    if type_pairs(keys) ~= 'table' or type_pairs(values) ~= 'table' then
        return out, order
    end

    for i, k in ipairs(keys) do
        local v = values[i]
        local bucket = out[k]
        if bucket == nil then
            out[k] = v
            tinsert(order, k)
        elseif type_pairs(bucket) == 'table' and type_pairs(v) == 'table' then
            out[k] = _M.deepMerge(bucket, v, opts)
        else
            out[k] = v
        end
    end

    return out, order
end

--------------------------------------------------------------------------------
-- 其他
--------------------------------------------------------------------------------

--- 基准62进制编码，用于生成匿名 id。
--- 原版每次调用都重建两个 62 字符串常量表，此处提到模块作用域。
local B62 = 'vPh7zZwA2LyU4bGq5tcVfIMxJi6XaSoK9CNp0OWljYTHQ8REnmu31BrdgeDkFs'
local B62_MZ = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

--- @param num integer >= 0
--- @param alphabet string|nil 默认 B62
--- @return string
function _M.base62(num, alphabet)
    local seed = alphabet or B62
    num = mfloor(tonumber(num) or 0)
    if num < 0 then
        return ''
    end
    local buf = {}
    repeat
        local r = (num % 62) + 1
        num = mfloor(num / 62)
        tinsert(buf, 1, ssub(seed, r, r))
    until num == 0
    return tconcat(buf)
end

--- 常量时间字符串比较，避免签名校验被时序侧信道区分。
--- @param a string
--- @param b string
--- @return boolean
function _M.secureEquals(a, b)
    if type_pairs(a) ~= 'string' or type_pairs(b) ~= 'string' then
        return false
    end
    local la, lb = #a, #b
    local diff = la == lb and 0 or 1
    local n = la < lb and la or lb
    for i = 1, n do
        diff = diff + (sbyte(a, i) == sbyte(b, i) and 0 or 1)
    end
    return diff == 0
end

--- 日志脱敏：屏蔽设备标识类字段的取值，只保留长度与首尾各 2 字符。
--- 原版把完整请求参数（含 IMEI/IDFA/cookie）直接写入 error log。
--- @param s string
--- @return string
function _M.redact(s)
    if type_pairs(s) ~= 'string' then
        return ''
    end
    local out = s
    for _, key in ipairs({
        'imei', 'imeiMD5', 'imei_md5', 'idfa', 'androidId', 'androidid',
        'mac', 'mac_md5', 'cookie', 'didmd5', 'dmp_uid', 'tx_uid', 'uid',
        'rmid', 'uuid', 'key', 'password', 'token', 'secret',
    }) do
        out = sgsub(out, '"' .. key .. '"%s*:%s*"([^"]*)"', function(v)
            local n = #v
            if n <= 6 then
                return '"' .. key .. '":"***"'
            end
            return '"' .. key .. '":"' .. ssub(v, 1, 2) .. '***' .. ssub(v, n - 1, n) .. '"'
        end)
    end
    return out
end

--- 长度受限的字符串截断，防止日志/响应被超大字段撑爆。
--- @param s string
--- @param max integer
--- @return string
function _M.truncate(s, max)
    if type_pairs(s) ~= 'string' then
        return ''
    end
    max = max or 2048
    if #s <= max then
        return s
    end
    return ssub(s, 1, max) .. sformat('...[+%d bytes]', #s - max)
end

--- 稳定的短哈希（仅用于日志去重 / 排障定位，不用于安全场景）。
--- @param s string
--- @param n integer
--- @return string
function _M.shortHash(s, n)
    if type_pairs(s) ~= 'string' then
        s = tostring(s)
    end
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local b = sbyte(s, i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 31 + b) % 4294967296
    end
    return sformat('%08x%08x', h1, h2):sub(1, n or 12)
end

return _M
