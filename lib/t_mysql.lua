local mysql = require("resty.mysql")
local conf = require('conf.config')
local _M = { _VERSION = '0.01' }
local mt = { __index = _M }

function _M.new(self, params)
    local db, err = mysql:new()
    if not db then
        return nil, err
    end
    return setmetatable({ db = db, opts = params }, mt)
end

function _M.connect(self)
    local db = self.db
    if not db then
        return nil, "not initialized"
    end
    db:set_timeout(tonumber(self.opts.timeout) or conf.mysqltimeout)
    local options = {
        host = self.opts.host,
        port = self.opts.port,
        database = self.opts.database,
        user = self.opts.user,
        password = self.opts.password
    }
    return db:connect(options)
end

function _M.close(self)
    local db = self.db
    if not db then
        return nil, "not initialized"
    end
    local ok, err = db:set_keepalive(conf.pool_max_idle_time, conf.pool_size)
    if not ok then
        ngx.log(ngx.ERR, "set http keepalive error : ", err)
    end
end

function _M.query(self)
    local db = self.db
    local ok, err = self:connect()

    if not ok then
        ngx.log(ngx.ERR, "failed to connect: ", err)
        return 500, '{"code":500,"msg":"failed to connect..."}'
    end
    local arr, number = {}, {}
    local res, err, errcode, sqlstate = db:query(self.opts.sqlbuilder);
    if not res then
        ngx.log(ngx.ERR, "bad result #1: ", err, ": ", errcode, ": ", sqlstate, ".")
        return 500, '{"code":500,"msg":"bad result #1: "' .. err, ": ", errcode, ": ", sqlstate, "." .. '}'
    end
    table.insert(arr, res)
    table.insert(number, 1)
    local i = 2
    while err == "again" do
        res, err, errcode, sqlstate = db:read_result()
        if not res then
            ngx.log(ngx.ERR, "bad result #", i, ": ", err, ": ", errcode, ": ", sqlstate, ".")
            return 500, '{"code":500,"msg":"bad result #' .. i .. ': "' .. err, ": ", errcode, ": ", sqlstate, "." .. '}'
        end
        table.insert(arr, res)
        table.insert(number, i)
        i = i + 1
    end
    self:close()
    return arr, number
end


return _M