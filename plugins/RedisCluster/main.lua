local conf = require('conf.cache')
local redis = require('lib.t_redis')
local redisC = require('resty.rediscluster')
local _M = { _VERSION = '0.01' }

function _M.runRedisCluster(source, cmd, ...)
    local config = {
        name = source,
        serv_list = conf.redisCluster[source],
        timeout = conf.redisCluster.timeout,
        keepalive_timeout = conf.redisCluster.pool_max_idle_time,
        keepalove_cons = conf.redisCluster.pool_size
    }

    local red = redisC:new(config)
    --    local mzid, err = red:eval("return redis.pcall('get', KEYS[1])", 1, tostring(key));
    local res, err = call_user_func({ red, cmd }, ...)
    if not res then
        ngx.log(ngx.ERR, "failed to [" .. source .. "] " .. cmd .. ": ", ... .. '|' .. err)
        return
    end
    return 200, res
end

function _M.runRedis(cmd, ...)
    local start = ngx.now()
    local red = redis:new()
    local res, err = call_user_func({ red, cmd }, ...)
    if not res then
        ngx.log(ngx.ERR, "failed to " .. cmd .. ": ", ... .. '|' .. err)
        return
    end
    ngx.log(ngx.ERR, "failed to " .. cmd .. ": ", ... .. '|')
    return res, math.floor((ngx.now() - start) * 1000)
end

return _M
