--- ngx 相关辅助：时间、随机标识、JSON 安全封装、请求体读取、响应写出。
---
--- 与 ngx 强耦合，因此与 `lib/util.lua`（纯函数、可脱离 OpenResty 测试）分开。

local util = require('lib.util')

local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local sformat = string.format
local ssub = string.sub
local smatch = string.match
local tinsert = table.insert

local mfloor = math.floor
local mrandom = math.random

local cjson = require('cjson.safe')

local _M = {}

_M._VERSION = '2.0'

--------------------------------------------------------------------------------
-- 时间
--------------------------------------------------------------------------------

--- 单调递增毫秒。
--- 全链路统一用它测量耗时——不要用 os.time / os.clock（秒精度且非单调）。
--- @return number
function _M.nowMs()
    return ngx.now() * 1000
end

--- 自进程启动以来的毫秒数，可用于错峰（jitter）。
--- @return number
function _M.uptimeMs()
    return (ngx.now() - _M._bootTime) * 1000
end

_M._bootTime = ngx.now()

--------------------------------------------------------------------------------
-- 随机标识
--------------------------------------------------------------------------------

--- 进程级随机源**只播种一次**。
---
--- 原版在每次生成 id 时都执行
---   `math.randomseed(tostring(ngx.now()*1000):reverse():sub(1,10))`
--- `ngx.now()` 是毫秒精度，同一毫秒内到达的请求会得到完全相同的种子，
--- 进而产生相同随机序列 —— 这在 ad/nad 适配器里被用作 HMAC 签名的 nonce，
--- 等价于 nonce 可预测、可重放。此处改为每 worker 播种一次。
function _M.seedWorker()
    local pid = ngx.worker and ngx.worker.pid and ngx.worker.pid() or 0
    local salt = ngx.now() * 1000000 + pid * 7919
    math.randomseed(mfloor(salt) % 2147483647)
end

--- 生成匿名设备标识（cookie 值）。
--- 结构：时间戳 base62(去掉首位) + 2 位 worker 指纹 + 2 位随机。
--- 随机部分来自已正确播种的进程级 PRNG，不再逐请求重播种子。
--- @return string
function _M.newIdCookie()
    local stamp = _M.base62(mfloor(ngx.now() * 1000))
    local body = ssub(stamp, 2)
    local pid = ngx.worker and ngx.worker.pid and ngx.worker.pid() or 0
    local workerFp = _M.base62((pid + mrandom(0, 61)) % (62 * 62))
    local rnd = _M.base62(mrandom(0, 61))
    return body .. workerFp .. rnd
end

_M.base62 = util.base62

--------------------------------------------------------------------------------
-- JSON
--------------------------------------------------------------------------------

--- 安全编码：失败返回 nil + err，绝不把 nil 交给 ngx.say。
--- 原版 `ngx.say(json_encode(str))` 未判空，cjson 编码失败时直接 500。
--- @param v any
--- @return string|nil
--- @return string|nil err
function _M.jsonEncode(v)
    local s, err = cjson.encode(v)
    if s == nil then
        return nil, err or 'encode failed'
    end
    return s
end

--- 安全解码。
--- @param s string
--- @return table|nil
--- @return string|nil err
function _M.jsonDecode(s)
    if util.isBlank(s) then
        return nil, 'empty body'
    end
    local v, err = cjson.decode(s)
    if v == nil then
        return nil, err or 'decode failed'
    end
    return v
end

--------------------------------------------------------------------------------
-- 请求体
--------------------------------------------------------------------------------

--- 读取并解析请求体。
---
--- 修正两处原版缺陷：
---   1. 原版只用 `ngx.req.get_body_data()`，当请求体超过 `client_body_buffer_size`
---      （默认 8k/16k）时它返回 nil，被误判成 "bad request"。此处回退读取临时文件。
---   2. 原版对 GET 与 POST 混用同一套 args 语义：GET 走 `get_uri_args()` 得到全字符串，
---      POST 走 JSON 得到带类型的表，同一接口两种入参形态。现统一：GET 也走 JSON body
---      之外仍保留 query 参数，但见入口层处理。
---
--- @param maxBytes number 上限
--- @return table|nil args
--- @return string|nil err
function _M.readBody(maxBytes)
    ngx.req.read_body()

    local body = ngx.req.get_body_data()
    if util.isBlank(body) then
        -- 请求体被 nginx 落盘了
        local path = ngx.req.get_body_file()
        if path then
            local f, err = io.open(path, 'rb')
            if not f then
                return nil, 'cannot open body file: ' .. tostring(err)
            end
            body = f:read(maxBytes + 1)
            f:close()
        end
    end

    if body == nil or body == '' then
        return nil, 'empty body'
    end
    if #body > maxBytes then
        return nil, sformat('body too large: %d > %d', #body, maxBytes)
    end

    local args, err = _M.jsonDecode(body)
    if args == nil then
        return nil, 'invalid json: ' .. tostring(err)
    end
    if type(args) ~= 'table' then
        return nil, 'json root must be an object'
    end
    return args
end

--------------------------------------------------------------------------------
-- 响应
--------------------------------------------------------------------------------

--- 统一响应写出。
--- @param status number HTTP 状态码
--- @param body table 待 JSON 序列化的对象
function _M.reply(status, body)
    ngx.status = status
    local s, err = _M.jsonEncode(body)
    if s == nil then
        ngx.log(ngx.ERR, 'response encode failed: ', tostring(err))
        -- 兜底用字面量，避免序列化失败导致二次失败
        ngx.header['Content-Type'] = 'application/json; charset=utf-8'
        ngx.say('{"code":500,"msg":"response encode failed"}')
        ngx.exit(500)
        return
    end
    ngx.header['Content-Type'] = 'application/json; charset=utf-8'
    ngx.say(s)
    ngx.exit(status)
end

--- 错误快捷响应。
--- @param status number
--- @param msg string
function _M.replyError(status, msg)
    ngx.status = status
    ngx.header['Content-Type'] = 'application/json; charset=utf-8'
    ngx.say(sformat('{"code":%d,"msg":"%s"}', status, msg:gsub('"', "'")))
    ngx.exit(status)
end

--------------------------------------------------------------------------------
-- 日志脱敏
--------------------------------------------------------------------------------

--- 记录一条已脱敏的排障日志。
--- @param level number ngx.ERR / ngx.WARN / ngx.NOTICE
--- @param msg string
function _M.logRedacted(level, msg)
    ngx.log(level, util.redact(util.truncate(tostring(msg), 4096)))
end

return _M
