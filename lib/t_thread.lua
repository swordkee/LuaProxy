local conf = require "conf.config"
local req = require('api.multiRequest')
local _M = { _VERSION = '0.02' }

function _M.thread(args)
    local threads = {}
    local co
    local spawn = ngx.thread.spawn
    local dmps = string.split(args.dmp, ',')
    local info
    if not isEmpty(dmps) then
        for _, v in pairs(dmps) do
            if in_table(v, conf.dmp) then
                co = spawn(require('api.' .. string.lower(v)).getInfo, args)
                table.insert(threads, co)
            end
        end
    end
    for k, _ in pairs(args) do
        if in_table(k, conf.dmp) and type(args[k]) == "table" then
            for kk, _ in pairs(args[k]) do
                co = spawn(require('api.' .. string.lower(k)).getInfo, args[k][kk])
                table.insert(threads, co)
            end
        end
    end

    if not isEmpty(args['tcp']) then
        for k, _ in pairs(args['tcp']) do
            co = spawn(req.requestHttp, args['tcp'][k])
            table.insert(threads, co)
        end
    end

    local used, data, arr = {}, {}, {}
    local start = ngx.now()
    for i = 1, #threads do
        --        local time = math.floor((ngx.now() - start) * 1000)
        --        repeat
        --            if time > conf.TIMEOUT then
        --                ngx.thread.kill(threads[i])
        --                break
        --            end
        --        until true

        local ok, info, source, time = ngx.thread.wait(threads[i])
        if ok then
            table.insert(used, time)
            table.insert(data, info)
            table.insert(arr, source)
        end
    end
    local tData = {}
    for _, v in pairs(table.unique(arr)) do
        local tbTable = table.findkeys(arr, v)
        if #tbTable > 1 then
            local tArr = {}
            for _, vv in pairs(tbTable) do
                table.merge(tArr, data[vv])
            end
            tData[v] = tArr
        else
            tData[v] = data[tbTable[1]]
        end
    end
    return tData, used
end

return _M
