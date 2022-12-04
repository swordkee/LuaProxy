local conf = require('conf.config')

if conf.log_format == 'file' then
    ngx.log(ngx.WARN, ngx.ctx.msg)
elseif conf.log_format == 'rsyslog' then
    local logger = require "resty.logger.socket"
    if not logger.initted() then
        local ok, err = logger.init {
            host = conf.rsyslog.ip,
            port = conf.rsyslog.port,
            sock_type = conf.rsyslog.sock_type,
            flush_limit = 1,
            drop_limit = 5678,
        }
        if not ok then
            ngx.log(ngx.ERR, "failed to initialize the logger: ",
                err)
            return
        end
    end

    local rfc5424 = require "resty.rfc5424"
    local msg = rfc5424.encode("LOCAL0", "INFO", "localhost", ngx.var.pid, "openresty", ngx.ctx.msg)
    local bytes, err = logger.log(msg)
    if err then
        ngx.log(ngx.ERR, "failed to log message: ", err)
        return
    end
else
    return
end
