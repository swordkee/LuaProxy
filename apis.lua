local cache = require('lib.t_cache')
local thr = require('lib.t_thread')

local function run()
    local request_method = ngx.var.request_method;
    local args = {};

    if "GET" == request_method then
        args = ngx.req.get_uri_args()
    elseif "POST" == request_method then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if body then
            args = json_decode(body);
        else
            return ngx.say('{"code":400,"msg":"bad request."}')
        end
    end
    if (args == nil) then
        return ngx.say('{"code":"400","msg":"json parsing error."}')
    end
    local id, key, keyid, mtype, sign =
    args['id'], args['key'], args['keyid'], args['mtype'], args['sign']

    if isEmpty(key) or isEmpty(mtype) or isEmpty(id) or isEmpty(keyid) then
        return ngx.say('{"code":400,"msg":"bad request."}')
    end

    local dmp, aut, passwd = cache.getSysById(id, keyid)

    if isEmpty(dmp) then
        return ngx.say('{"code":400,"msg":"dmp not existed."}')
    end
    --    pr(dmp, aut, passwd)
    local host = ngx.var.host or "127.0.0.1"
    local mzpath = "/apis?id=" .. id .. "&key=" .. key .. "&keyid=" .. keyid .. "&mtype=" .. mtype
    local token = ngx.escape_uri(string.sub(ngx.encode_base64(ngx.hmac_sha1(passwd, method .. host .. mzpath)), 1, 16))
    --    pr(token)
    if token ~= sign then
        return ngx.say('{"code":401,"msg":"Requested with invalid token."}')
    end
    local str, used = thr.thread(key, dmp, args)
    ngx.say(json_encode(str))
    ngx.eof()
    ngx.ctx.msg = json_encode({ args = args, result = str, used = used })
end

run()
