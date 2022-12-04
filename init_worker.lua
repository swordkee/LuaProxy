local conf = require('conf.config')
local GT = require("api.gt")

local handler
handler = function(premature)
    if premature then
        return
    end

    GT.getAccesser()

    local ok, err = ngx.timer.at(conf.delay, handler)
    if not ok then
        ngx.log(ngx.ERR, "failed to create the timer: ", err)
        return
    end
end

local ok, err = ngx.timer.at(conf.delay, handler)
if not ok then
    ngx.log(ngx.ERR, "failed to create the timer: ", err)
    return
end

