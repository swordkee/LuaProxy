local mysql = require('lib.t_mysql')
local config = require('plugins.multi.config')
local M = {}

function M.thread(args)
    local threads = {}
    local co
    local spawn = ngx.thread.spawn
    local info

    local dbCount = table.len(config.mysql)
    if isEmpty(args.data) or dbCount == 0 then
        return {}, 0, 0
    end
    local data, callBack = {}, {}
    for i = 1, dbCount do
        data[i], callBack[i] = {}, {}
    end

    local i = 1
    for k, v in pairs(args.data) do
        local ks = i % dbCount + 1
        for kk, _ in pairs(config.mysql) do
            if (ks == kk) then
                table.insert(data[kk], v)
                table.insert(callBack[kk], k)
            end
        end
        i = i + 1
    end
    for k, v in pairs(config.mysql) do
        local options = {
            host = v.hostname,
            port = v.port,
            database = v.database,
            user = v.username,
            password = v.password,
            timeout = v.timeout,
            sqlbuilder = tostring(ngx.unescape_uri(table.concat(data[k]))),
            callBack = (callBack[k])
        }
        co = spawn(M.query, options)
        table.insert(threads, co)
    end

    local used, data, numbers = {}, {}, {}
    for i = 1, #threads do
        local ok, info, number, time = ngx.thread.wait(threads[i])
        if ok and not isEmpty(info) then
            table.merge(data, info)
            table.insert(used, time)
        end
    end
    return data, used
end

function M.query(params)
    local start = ngx.now()
    local callBack = params.callBack
    local tArrays = {}
    if isEmpty(params.sqlbuilder) then
        return {}, 0, 0
    end
    local db = mysql:new(params);
    local tArray, i = db:query()
    if isEmpty(tArray) then
        return {}, 0, 0
    end
    for k, v in pairs(tArray) do
        tArrays[callBack[k]] = v
    end
    return tArrays, i, math.floor((ngx.now() - start) * 1000)
end

return M
