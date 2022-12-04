local function run()
    local args = ngx.req.get_uri_args()
    if not isEmpty(ngx.var.cookie_a) then
        args['rmid'] = ngx.var.cookie_a
    else
        args['rmid'] = createIdCookie()
        local expires = ngx.cookie_time(ngx.now() + 86400 * 365 * 2)
        ngx.header["Set-Cookie"] = { "a=" .. args['rmid'] .. "; expires=" .. expires .. "; path=/; domain=xxxx.cn" }
        ngx.header["PSP"] = { 'CP="IDC DSP COR ADM DEVi TAIi PSA PSD IVAi IVDi CONi HIS OUR IND CNT"' }
    end
    args['time'] = math.floor(ngx.now() * 1000)
    ngx.header["Content-Type"] = "image/gif"
    ngx.header["Expires"] = -1
    ngx.header["Cache-Control"] = "no_cache"
    ngx.header["Pragma"] = "no-cache"
    ngx.say(ngx.decode_base64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQImWNgYGBgAAAABQABh6FO1AAAAABJRU5ErkJggg=="))
    ngx.eof()
    ngx.ctx.msg = json_encode({ args = args })
end

run()
