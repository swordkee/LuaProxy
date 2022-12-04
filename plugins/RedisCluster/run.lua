local main = require('plugins.RedisCluster.main')

local function run()
    local request_method = ngx.var.request_method;
    local args;

    if "POST" == request_method then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if body then
            args = json_decode(body);
        else
            return ngx.say('{"code":"400","msg":"bad request."}')
        end
    end
    if (args == nil) then
        return ngx.say('{"code":"400","msg":"json parsing error."}')
    end
    local info, used = main.runRedis(unpack(args))
    ngx.say(json_encode(info))
    ngx.eof()
    ngx.ctx.msg = json_encode({ args = args, used = used })
end

--curl -i -X POST -H "'Content-type':'application/x-www-form-urlencoded', 'charset':'utf-8', 'Accept': 'application/json'" -d '["hmget","DEV_User:Login:Token:2","token"]' "http://127.0.0.1:8083/redis"
run()