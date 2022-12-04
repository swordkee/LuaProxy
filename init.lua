local conf = require('conf.config')
local utils = require('utils')
local json = require('cjson.safe')

function isEmpty(str)
    local t = type(str)
    if t == "string" then
        return str == nil or string.len(str) == 0 or str == "" or str == ngx.null
    elseif t == "table" then
        return #str == 0 and table.len(str) == 0 or next(str) == nil
    elseif t == "number" then
        return (str == 0 and { true } or { false })[1]
    elseif t == "boolean" then
        return str == false
    elseif t == 'nil' then
        return true
    else
        return str;
    end
end

--简化三元表达式
function on(boolValue, trueValue, falseValue)
    return (boolValue and { trueValue } or { falseValue })[1]
end

function pr(...)
    if conf.DEBUG == true then
        local d = require "resty.dump"
        d.dump(...)
    end
end

--function isJsonCheck(josnschema, arrayParams)
--    if conf.JSONSCHEMA == false then
--        return true
--    else
--        if isEmpty(arrayParams) then
--            return false
--        end
--        local rjson = require('rapidjson')
--        local schema = rjson.SchemaDocument(josnschema)
--        local validator = rjson.SchemaValidator(schema)
--        local ok, message = validator:validate(rjson.Document(rjson.encode(arrayParams)))
--        return ok, message
--    end
--end

string.split = function(str, delimiter)
    if isEmpty(str) or isEmpty(delimiter) then
        return nil
    end
    return utils.split(str, delimiter) --3132
    --        local result = {} -- 7530
    --        for match in (str .. delimiter):gmatch("(.-)" .. delimiter) do
    --            table.insert(result, match)
    --        end
    --        return result
end

string.trim = function(str)
    if type(str) ~= "string" or isEmpty(str) then
        return nil, "the string parameter is nil"
    end
    return utils.trim(str) --1064
    --    return ngx.re.gsub(str, "\\s", "%20", "jo")
    --    return string.gsub(str, "^%s*(.-)%s*$", "%1") --3886
end

table.len = function(t)
    local c = 0
    for _, v in pairs(t) do
        c = c + 1
    end
    return c
end

table.merge = function(a, b)
    if type(a) == 'table' and type(b) == 'table' then
        for k, v in pairs(b) do if type(v) == 'table' and type(a[k] or false) == 'table' then table.merge(a[k], v) else a[k] = v end end
    end
    return a
end

table.unique = function(t)
    local check = {}
    local res = {}
    for i, v in ipairs(t) do
        if not (check[v]) then
            check[v] = true
            res[1 + #res] = v
        end
    end
    return res
end

table.findkeys = function(t, value)
    local res = {}
    for k, v in pairs(t) do
        if v == value then
            res[1 + #res] = k
        end
    end
    return res
end

table.invert = function(t)
    local res = {}
    for k, v in pairs(t) do
        res[v] = k
    end
    return res
end

function bin2hex(s)
    s = string.gsub(s, "(.)", function(x) return string.format("%02X", string.byte(x)) end)
    return s
end

function table.callBack(callBack, source, code, mtype, msg)
    local tMsg = { ["400"] = "bad request.", ["500"] = "failed to connect..." }
    local msgs = on(not isEmpty(msg), msg, tMsg[tostring(code)])
    local used = {}
    if mtype ~= 'redis' then
        used[callBack] = '0'
    else
        used[callBack] = '0|-2'
    end
    return {
        [callBack] = {
            code = code,
            msg = msgs
        }
    }, source, used
end

function in_table(value, table)
    if isEmpty(table) then
        return false
    end
    for _, v in pairs(table) do
        if v == value then
            return true;
        end
    end
    return false;
end

function base62(num, ver)
    local BASE_STRING = "vPh7zZwA2LyU4bGq5tcVfIMxJi6XaSoK9CNp0OWljYTHQ8REnmu31BrdgeDkFs"
    local BASE_STRING_MZ = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local seed = on(ver ~= 'mz', BASE_STRING, BASE_STRING_MZ)
    local tab = {}
    repeat
        local r = (num % 62) + 1
        num = math.floor(num / 62)
        table.insert(tab, 1, string.sub(seed, r, r))
    until num == 0

    return table.concat(tab)
end

function createIdCookie()
    local str = base62(math.floor(ngx.now() * 1000))
    local s1 = string.sub(str, 2, string.len(str))
    math.randomseed(tostring(ngx.now() * 1000):reverse():sub(1, 10))
    local s2 = string.sub(base62((ngx.var.pid + math.random(0, 61)) % (62 * 62)), -2, 2)
    local s3 = base62(math.random(0, 61));
    return s1 .. s2 .. s3
end

function json_decode(t)
    return json.decode(t)
end

function json_encode(t)
    return json.encode(t)
end

function call_user_func(func, ...)
    local t = type(func)
    if t == "function" then
        return func(...)
    elseif t == "string " then
        if _G[func] == nil or type(_G[func]) ~= "function" then
            ngx.log(ngx.ERR, "function is not defined '" .. func .. "'")
        end
        return _G[func](...)
    elseif t == "table" then
        local _instance = func[1]
        local _method = func[2]
        if _instance == nil or _method == nil then
            ngx.log(ngx.ERR, "instance or method name is nil")
        end
        if _instance[_method] == nil then
            ngx.log(ngx.ERR, "class method is not defined '" .. _method .. "'")
        end
        return _instance[_method](_instance, ...)

    else
        ngx.log(ngx.ERR, "func is not matched type '" .. type(func) .. "'")
    end
end