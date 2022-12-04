local main = require('plugins.scylla.main')
local function run()
    local request_method = ngx.var.request_method;
    local args = {};
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


    local info, used = main.runCassandraCluster(args)
    ngx.ctx.msg = json_encode({ args = args, used = used })
    ngx.say(json_encode(info))
end

run()
--curl -i -X POST -H "'Content-type':'application/x-www-form-urlencoded', 'charset':'utf-8', 'Accept': 'application/json'" -d '{"batch":[{"query":"INSERT INTO mapping.youku_dmp(rmid, uid, last_access) VALUES (?,?,?)","args":["456789","9876543","2016-04-06 13:06:11.534"]},{"query":"INSERT INTO mapping.youku_dmp(rmid, uid, last_access) VALUES (?,?,?)","args":["234567","765432","2016-04-06 13:06:11.534"]},{"query":"INSERT INTO mapping.youku_dmp(rmid, uid, last_access) VALUES (?,?,?)","args":["345678","876543","2016-04-06 13:06:11.534"]}],"execute":{"query":"SELECT uid FROM mapping.youku_dmp WHERE rmid = ? Limit ?","args":["123456",10]}}' "http://127.0.0.1:8083/scylla"