local cluster = require 'resty.cassandra.cluster'
local conf = require('conf.cassandra')
local _M = { _VERSION = '0.01' }
local mt = { __index = _M }
--官方文档
--https://thibaultcha.github.io/lua-cassandra/index.html
--下载地址
--https://github.com/thibaultCha/lua-cassandra

function _M.new(self, params)
    local options = {
        shm = conf.lua_shared_dict,
        contact_points = conf.cassandra.ip,
        keyspace = conf.keyspace,
        timeout_read = conf.timeout_read,
        timeout_connect = conf.timeout_connect,
        lock_timeout = conf.lock_timeout / 1000,
        protocol_version = conf.protocol_version,
        ssl = conf.ssl,
        verify = conf.verify,
    }
    local db, err = cluster.new(options)
    if not db then
        ngx.log(ngx.ERR, 'could not create cluster: ', err)
        return nil, err
    end
    return setmetatable({ db = db, opts = params }, mt)
end

function _M.execute(self, query, args, options, coordinator)
    local db = self.db
    if not db then
        return nil, "not initialized"
    end
    local res, err = db:execute(query, args, options, coordinator);
    if not res then
        ngx.log(ngx.ERR, 'could not retrieve execute: ', err)
        return 500, '{"code":500,"msg":"bad result execute: "' .. err .. '}'
    end
    return res
end

function _M.batch(self, queries, options, coordinator)
    local db = self.db
    if not db then
        return nil, "not initialized"
    end

    local res, err = db:batch(queries, options, coordinator);
    if not res then
        ngx.log(ngx.ERR, 'could not retrieve batch: ', err)
        return 500, '{"code":500,"msg":"bad result batch: "' .. err .. '}'
    end
    return res
end

function _M.dmpCall(self)
    local db = self.db
    if not db then
        return nil, "not initialized"
    end
    local sql = string.format("SELECT uid FROM " .. conf.keyspace .. ".%s WHERE rmid = ? Limit 1",
        conf.cassandra[self.opts.dmp].table)
    local res, err = db:execute(sql, { self.opts.key })
    if not res then
        ngx.log(ngx.ERR, 'could not retrieve dmpCall: ', err)
        return 500, '{"code":500,"msg":"bad result dmpCall : "' .. err .. '}'
    end

    local re = ''

    if not isEmpty(res[1]) then
        re = res[1].uid
    end
    return re
end

return _M