--- 统一响应信封与状态码契约。
---
--- ## 为什么需要这一层
--- 2017 年版本由各厂商适配器自行决定 `code` 的含义，同一个码在不同适配器里
--- 语义不同（404 既可能是「上游报错」也可能是「未命中」），`used` 字段更是有
--- 4 种格式（`-2` / `0|-2` / `123` / `12|34`）。调用方无法写出一段通用逻辑，
--- 也没有任何东西能校验它。本模块把契约收敛到一处，并让所有适配器共用。
---
--- ## 契约
--- 每个数据源最终归并为：
--- ```lua
--- {
---   code    = 200,          -- 见下方 CODES
---   msg     = "",           -- 人类可读，仅 code ~= 200 时有值
---   result  = { ... },      -- 命中的标签/人群包列表；未命中恒为 {}
---   elapsed = 12,           -- 本数据源耗时，毫秒
--- }
--- ```
--- `result` 恒为数组（空数组表示未命中），调用方无需分支判断类型。
---
--- 本模块不引用 ngx，可直接单元测试。

local util = require('lib.util')

local type = type
local m_floor = math.floor

local _M = {}

_M._VERSION = '2.0'

--- 耗时规整为非负整数毫秒。
--- 必须定义在使用它的函数之前：Lua 按编译期词法作用域解析名字，
--- 若先引用后声明，引用会落到全局并在运行时变成 nil 调用。
--- @param v any
--- @return integer
local function ms(v)
    if type(v) ~= 'number' or v ~= v then  -- v ~= v 过滤 NaN
        return 0
    end
    return v < 0 and 0 or m_floor(v)
end

--- 状态码 → 语义。所有适配器必须从这里取，不得自定义。
_M.CODES = {
    HIT                 = 200, -- 命中，返回的标签已在 result 中
    NO_MATCH            = 204, -- 上游正常应答但未命中任何标签
    BAD_REQUEST         = 400, -- 入参缺失或非法
    UNAUTHORIZED        = 401, -- HMAC 签名校验失败
    FORBIDDEN           = 403, -- 上游明确拒绝，或目标不在白名单
    NOT_FOUND           = 404, -- 未注册的适配器 / 上游不可达
    METHOD_NOT_ALLOWED  = 405, -- HTTP 方法不支持
    IDENTITY_MISS       = 410, -- rmid -> uid 映射缺失（上游可查，但本地无映射）
    PAYLOAD_TOO_LARGE   = 413, -- 请求体超限
    INTERNAL            = 500, -- 适配器内部异常
    UPSTREAM_BAD_BODY   = 502, -- 上游返回了无法解析的响应
    UPSTREAM_UNAVAILABLE = 503, -- 上游连接失败
    UPSTREAM_TIMEOUT    = 504, -- 超过本数据源的时间预算
}

--- 码 → 默认文案
_M.MESSAGES = {
    [200] = 'ok',
    [204] = 'no match',
    [400] = 'bad request',
    [401] = 'unauthorized',
    [403] = 'forbidden',
    [404] = 'not found',
    [405] = 'method not allowed',
    [410] = 'identity mapping not found',
    [413] = 'payload too large',
    [500] = 'internal error',
    [502] = 'upstream returned an unparsable body',
    [503] = 'upstream unavailable',
    [504] = 'upstream timeout',
}

--- 构造成功信封。
--- @param result table 命中标签数组
--- @param elapsed number 毫秒
--- @return table
function _M.hit(result, elapsed)
    local r = result
    if type(r) ~= 'table' or not util.isArray(r) then
        r = {}
    end
    if #r == 0 then
        return _M.envelope(_M.CODES.NO_MATCH, nil, elapsed)
    end
    return { code = _M.CODES.HIT, msg = '', result = r, elapsed = elapsed or 0 }
end

--- 构造未命中信封。
--- @param elapsed number
--- @return table
function _M.noMatch(elapsed)
    return _M.envelope(_M.CODES.NO_MATCH, nil, elapsed)
end

--- 构造失败信封。
--- @param code number 必须取自 CODES
--- @param detail string|nil 追加到默认文案之后，便于排障
--- @param elapsed number
--- @return table
function _M.fail(code, detail, elapsed)
    return _M.envelope(code, detail, elapsed)
end

--- 统一的信封构造函数（内部使用；适配器一般用 hit / noMatch / fail）。
--- @param code number
--- @param detail string|nil
--- @param elapsed number
--- @return table
function _M.envelope(code, detail, elapsed)
    local base = _M.MESSAGES[code] or 'unknown'
    local msg = base
    if detail ~= nil and detail ~= '' then
        msg = base .. ': ' .. util.truncate(tostring(detail), 200)
    end
    return {
        code = code,
        msg = msg,
        result = {},
        elapsed = ms(elapsed),
    }
end

--- 把 {code,msg,result} 形态的旧式返回值归一成信封。
--- 用于渐进迁移：适配器尚未改造时由 orchestrator 兜底转换。
--- @param legacy any
--- @param elapsed number
--- @return table
function _M.fromLegacy(legacy, elapsed)
    if type(legacy) ~= 'table' then
        return _M.envelope(_M.CODES.INTERNAL, 'adapter returned ' .. type(legacy), elapsed)
    end
    local code = tonumber(legacy.code) or _M.CODES.INTERNAL
    if not _M.MESSAGES[code] then
        code = _M.CODES.INTERNAL
    end
    if code == _M.CODES.HIT and util.isBlank(legacy.result) then
        code = _M.CODES.NO_MATCH
    end
    return {
        code = code,
        msg = util.orElse(legacy.msg, _M.MESSAGES[code] or 'unknown'),
        result = (code == _M.CODES.HIT and legacy.result) or {},
        elapsed = ms(elapsed),
    }
end

--- 判断是否为「可接受」结果：命中或正常未命中。
--- 上游不可达/超时也应被上游调用方视为「查不到」而非「系统故障」，
--- 因此这里把 5xx 也算作可接受，仅供日志分级与监控使用。
--- @param env table
--- @return boolean
function _M.isHit(env)
    return type(env) == 'table' and env.code == _M.CODES.HIT
end

--- 扁平化输出：把 { source -> envelope } 转成 { source -> result } 的数组映射，
--- 便于调用方直接消费。并同时返回每个 source 的 code 供排障。
--- @param grouped table
--- @return table hits, table codes
function _M.flatten(grouped)
    local hits, codes = {}, {}
    if type(grouped) ~= 'table' then
        return hits, codes
    end
    for source, env in pairs(grouped) do
        if type(env) == 'table' then
            codes[source] = env.code
            if env.code == _M.CODES.HIT and type(env.result) == 'table' then
                hits[source] = env.result
            end
        end
    end
    return hits, codes
end

return _M
