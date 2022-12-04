local thr = require('lib.t_thread')

local function run()
    local request_method = ngx.var.request_method;
    local args;

    if "GET" == request_method then
        args = ngx.req.get_uri_args()
    elseif "POST" == request_method then
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
    local str, used = thr.thread(args)
    --    ngx.eof()
    ngx.ctx.msg = json_encode({ args = args, result = str, used = used })
    ngx.say(json_encode(str))
end

run()
