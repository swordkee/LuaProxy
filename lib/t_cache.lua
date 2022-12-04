local conf = require('conf.cache')
local dict = ngx.shared.dataDict
local redis = require('lib.t_redis')
local redisC = require('resty.rediscluster')
local Cluster = require('lib.t_cassandra')
local _M = { _VERSION = '0.02' }

function _M.getRedisCluster(key, source)
    local config = {
        name = source,
        serv_list = conf.redisCluster[source],
        timeout = conf.redisCluster.timeout,
        keepalive_timeout = conf.redisCluster.pool_max_idle_time,
        keepalove_cons = conf.redisCluster.pool_size
    }

    local red = redisC:new(config)
    --    local mzid, err = red:eval("return redis.pcall('get', KEYS[1])", 1, tostring(key));
    local res, err = red:get(key)
    if not res then
        ngx.log(ngx.ERR, "failed to get key: ", key .. '|' .. err)
        return
    end
    return 200, res
end

function _M.getCassandraCluster(key, source)
    local cluster, err = Cluster:new({ key = key, dmp = source })
    if not cluster then
        ngx.log(ngx.ERR, 'could not create cluster: ', err)
        return;
    end

    local rows, err = cluster:dmpCall()
    if not rows then
        ngx.log(ngx.ERR, 'could not retrieve users: ', key .. '|' .. err)
        return 'could not retrieve users: ', key .. '|' .. err;
    end
    return 200, rows
end

function _M.getRedis(key)
    local red = redis:new()
    local res, err = red:get(key)
    if not res then
        ngx.log(ngx.ERR, "failed to get key: ", key .. '|' .. err)
        return
    end
    return res
end

function _M.getRedisByZset(key)
    local red = redis:new()
    local count, err = red:zcount(conf.cacheTable .. key, 0, 999999)
    if count == 0 then
        return
    end

    local res, err = red:zrange(conf.cacheTable .. key, 0, 0)
    if not res then
        ngx.log(ngx.ERR, "failed to zrange key: ", err)
        return
    end
    local zres, err = red:zremrangebyrank(conf.cacheTable .. key, 0, 0)
    if not zres then
        ngx.log(ngx.ERR, "failed to zremrangebyrank key: ", err)
        return
    end
    return res[1]
end

function _M.getSysInfo()
    local red = redis:new()
    local count, err = red:zcount(conf.orderTable .. "index", 0, 999)

    if not count then
        ngx.log(ngx.ERR, "failed to llen DataMax: ", err)
        return
    end
    if tonumber(count) == 0 then
        return
    end
    --取orderid索引
    local oArray, err = red:zrevrange(conf.orderTable .. "index", 0, 999)
    if not oArray then
        ngx.log(ngx.ERR, "failed to lrange DataMax orderid", err)
        return
    end
    red:init_pipeline()
    --取orderid数据
    for _, v in pairs(oArray) do
        red:hmget(conf.orderTable .. v, "dmp", "aut")
    end

    local results, err = red:commit_pipeline()

    if not results then
        ngx.log(ngx.ERR, "failed to commit the pipelined requests: ", err)
        return
    end

    for k, res in ipairs(results) do
        if type(res) == "table" then
            repeat
                if isEmpty(res[1]) then
                    break
                else
                    dict:set(conf.orderTable .. oArray[k] .. ":dmp", res[1])
                end
                if not isEmpty(res[2]) then
                    dict:set(conf.orderTable .. oArray[k] .. ":aut", res[2])
                end
            --                ngx.say(dict:get(conf.orderTable .. oArray[k] .. ":dmp"))
            until true --contine
        end
    end

    --取service索引

    local count, err = red:zcount(conf.serviceTable .. "index", 0, 999)

    if not count then
        ngx.log(ngx.ERR, "failed to llen DataMax service: ", err)
        return
    end

    if tonumber(count) == 0 then
        return
    end
    --取orderid索引
    local sArray, err = red:zrevrange(conf.serviceTable .. "index", 0, 999)
    if not sArray then
        ngx.log(ngx.ERR, "failed to lrange DataMax service", err)
        return
    end

    red:init_pipeline()

    --取service数据
    for _, v in pairs(sArray) do
        red:get(conf.serviceTable .. v)
    end
    results, err = red:commit_pipeline()

    if not results then
        ngx.log(ngx.ERR, "failed to commit the pipelined requests: ", err)
        return
    end

    for k, res in ipairs(results) do
        if type(res) == "string" and not isEmpty(res) then
            dict:set(conf.serviceTable .. sArray[k], res)
        end
    end

    return ok
end

function _M.getSysById(id, keyid)

    local dmp, aut, passwd

    --    dmp = dict:get(conf.orderTable .. id .. ":dmp")
    --    aut = dict:get(conf.orderTable .. id .. ":aut")
    --    passwd = dict:get(conf.serviceTable .. keyid)
    --    if (not isEmpty(dmp)) and (not isEmpty(passwd)) then
    --        return dmp, aut, passwd
    --    end
    local red = redis:new()
    red:init_pipeline()
    red:hmget(conf.orderTable .. id, "dmp", "aut")
    red:get(conf.serviceTable .. keyid)
    local results, err = red:commit_pipeline()
    if not results then
        ngx.log(ngx.ERR, "failed to commit the pipelined requests: ", err)
        return
    end
    for _, res in ipairs(results) do
        if type(res) == "table" then
            repeat
                if isEmpty(res[1]) then
                    break
                else
                    dmp = res[1]
                    dict:set(conf.orderTable .. id .. ":dmp", res[1])
                end
                if not isEmpty(res[2]) then
                    aut = res[2]
                    dict:set(conf.orderTable .. id .. ":aut", res[2])
                end
            until true
        else
            if not isEmpty(res) then
                passwd = res
                dict:set(conf.serviceTable .. keyid, res)
            end
        end
    end
    return dmp, aut, passwd
end

function _M.push(channel)
    local red = redis:new({ timeout = 0 })
    local func = red:subscribe(channel)
    if not func then
        return nil
    end

    while true do
        local res, err = func()
        if err then
            func(false)
        end
        if res then
            local item = res[3]
            ngx.log(ngx.ERR, "failed to send text: ", item)
        end
    end
end

return _M