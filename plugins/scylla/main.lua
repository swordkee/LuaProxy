local Cluster = require('lib.t_cassandra')
local _M = { _VERSION = '0.01' }

function _M.runCassandraCluster(params)

    local cluster, err = Cluster:new(params)
    if not cluster then
        ngx.log(ngx.ERR, 'could not create cluster: ', err)
        return;
    end
    local rows, rowsExecute, rowsBatch, err
    if not isEmpty(params.execute) then
        rowsExecute, err = cluster:execute(params.execute.query, params.execute.args, params.execute.options, params.execute.coordinator)
        if not rowsExecute then
            ngx.log(ngx.ERR, 'could not retrieve execute: ', err)
            return 'could not retrieve execute: ', err;
        end
    end

    local queries = {}
    if not isEmpty(params.batch) then
        local tArray = {}
        for _, v in pairs(params.batch) do
            tArray[1] = v.query
            tArray[2] = v.args
            table.insert(queries, tArray)
        end

        if #queries > 0 then
            rowsBatch, err = cluster:batch(queries, params.batch.options, params.batch.coordinator)
            if not rowsBatch then
                ngx.log(ngx.ERR, 'could not retrieve batch: ', err)
                return 'could not retrieve batch: ', err;
            end
        end
    end
    return { execute = rowsExecute, batch = rowsBatch }, 200
end

return _M
