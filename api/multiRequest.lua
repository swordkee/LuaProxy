local sys = require('conf.system')
local H = require('lib.t_http')
local S = require('lib.t_socket')
local source = "tcp"
local M = {}

function M.requestHttp(params)
    local start = ngx.now()
    local callBack = on(isEmpty(params.callBack), source .. "_" .. params.host, params.callBack)
    local data, used = {}, {}
    data[callBack] = {}
    data[callBack].result = {}
    data[callBack].code = 404
    used[callBack] = '0|-2'

    --    local ok, message = isJsonCheck(sys[source].jsonSchema, params)
    --    if ok == false then
    --        return table.callBack(callBack, source, 400, '', message)
    --    end

    local options = {
        ["host"] = params.host,
        ["protocol"] = params.protocol,
        ["method"] = params.method,
        ["timeout"] = params.timeout,
        ["port"] = tonumber(params.port),
        ["path"] = params.path,
        ["data"] = params.data,
    }

    local httpc = H:new(options);
    local status, body
    if isEmpty(params.proxy) then
        status, body = httpc:requset()
    else
        status, body = httpc:capture()
    end
    if status == 200 then
        data[callBack].result = body
        data[callBack].code = status
        used[callBack] = math.floor((ngx.now() - start) * 1000)
        return data, source, used
    end
    return data, source, used
end

function M.requestSocket(params)
    local callBack = on(isEmpty(params.callBack), "socket_" .. params.host, params.callBack)
    local start = ngx.now()
    local options = {
        ["host"] = params.host,
        ["port"] = tonumber(params.port),
        ["data"] = params.data,
        ["len"] = tonumber(params.len),
    }
    local soc = S:new(options);
    local body, status
    if isEmpty(params.len) then
        status, body = soc:requset();
    else
        status, body = soc:requset16();
    end
    local time = math.floor((ngx.now() - start) * 1000)

    return '"' .. callBack .. '":"' .. body .. '"', callBack .. ':' .. time
end

return M
