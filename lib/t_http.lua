local http = require("resty.http")
local conf = require('conf.config')

local _M = { _VERSION = '0.01' }
local mt = { __index = _M }

function _M.new(self, params)
    local httpc, err = http.new()
    if not httpc then
        return nil, err
    end

    if isEmpty(params.method) then
        params.method = 'GET';
    end
    if not isEmpty(params.protocol) and params.protocol == "https" then
        params.protocol = "https";
    else
        params.protocol = "http";
    end
    if isEmpty(params.port) and params.protocol == "https" then
        params.port = 443;
    elseif isEmpty(params.port) then
        params.port = 80;
    else
        params.port = tonumber(params.port)
    end

    return setmetatable({ httpc = httpc, opts = params }, mt)
end

--http通用连接
function _M.connect(self)
    local httpc = self.httpc
    if not httpc then
        return nil, "not initialized"
    end
    httpc:set_timeout(tonumber(self.opts.timeout) or conf.httptimeout)
    if not isEmpty(self.opts.port) then
        return httpc:connect(self.opts.host, self.opts.port)
    else
        return httpc:connect(self.opts.host)
    end
end

function _M.close(self)
    local httpc = self.httpc
    if not httpc then
        return nil, "not initialized"
    end
    local count = ngx.worker.count()
--    local ok, err = httpc:set_keepalive(conf.pool_max_idle_time, math.floor(conf.pool_size / count))
    local ok, err = httpc:set_keepalive(conf.pool_max_idle_time, conf.pool_size )
    if not ok then
        ngx.log(ngx.ERR, "set http keepalive error : ", err)
    end
end

--http通用请求
function _M.requset(self)
    local httpc = self.httpc
    local ok, err = self:connect()

    if not ok then
        ngx.log(ngx.ERR, self.opts.host.." failed to connect: ", err)
        return 500, '{"code":500,"msg":"'..self.opts.host..' failed to connect..."}'
    end
    if self.opts.protocol == "https" then
        httpc:ssl_handshake(nil, self.opts.host, false)
    end

    local options = on(isEmpty(self.opts.options), {}, self.opts.options)
    local method = string.upper(self.opts.method)
    options["Connection"] = "Keep-Alive";
    if method == "POST" then
        options["Content-Type"] = "application/x-www-form-urlencoded"
        options["Content-Type"] = "application/json"
        options["Content-Length"] = string.len(self.opts.data)
    end
    local resp, err = httpc:request {
        method = method,
        path = self.opts.path,
        body = on(method == "POST", self.opts.data, ""),
        headers = options,
        version = 1.1
    };

    if not resp then
        if err == "timeout" then
            httpc:close()
        end
        return ngx.log(ngx.ERR, "failed to request: ", err)
    end

    local body, err = resp:read_body()
    if not body then
        return nil, err
    end
    self:close()
    return resp.status, body
end

function _M.capture(self)
    local method
    if self.opts.method == "GET" then
        method = ngx.HTTP_GET
    elseif self.opts.method == "POST" then
        method = ngx.HTTP_POST
    end
    -- upstream反向代理
    local http_proxy = conf.http_proxy
    if in_table(self.opts.host, http_proxy) then
        self.opts.host = table.invert(http_proxy)[self.opts.host]
    end
    if method == "POST" then
        ngx.req.set_header("Content-Type", "application/json;charset=utf8");
        ngx.req.set_header("Accept", "application/json");
    end
    local resp = ngx.location.capture('/proxy/' .. self.opts.protocol .. '/' .. self.opts.host .. self.opts.path, {
        method = method,
        body = self.opts.data,
    })
    if resp.body then
        return resp.status, resp.body
    end
end

return _M