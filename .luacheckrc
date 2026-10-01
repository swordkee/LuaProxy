-- luacheck 配置
--
-- 原版无任何静态检查，这直接导致了一类"肉眼很难发现"的缺陷长期存活，例如：
--   t_socket.lua:78,101   sock.close()   —— 少了一个冒号（应为 sock:close()）
--   t_socket.lua:94       return null    —— null 是未定义全局，实际返回 nil
--   t_cache.lua:156       return ok      —— ok 是未定义全局，实际返回 nil
--   apis.lua:37           method         —— 未声明，取全局 nil
--   t_thread.lua:40       ngx.thread.kill —— 整段被注释，从未执行
-- 这几处 luacheck 均能直接报出。
--
-- 安装：luarocks install luacheck
-- 运行：luacheck .

std             = "luajit"
cache           = true
max_line_length = 120

exclude_files = {
    "resty/",          -- 第三方 vendored 代码，不做检查
    ".luarocks/",
    "spec/",
}

-- 允许的标准库
read_globals = {
    -- ngx
    "ngx",
    -- OpenResty 特有
    "ngx.re", "ngx.req", "ngx.resp", "ngx.socket", "ngx.shared", "ngx.location",
    "ngx.var", "ngx.header", "ngx.ctx", "ngx.worker", "ngx.timer",
    "ngx.null", "ngx.HTTP_GET", "ngx.HTTP_POST", "ngx.HTTP_PUT", "ngx.HTTP_DELETE",
    "ngx.ERR", "ngx.WARN", "ngx.NOTICE", "ngx.INFO", "ngx.DEBUG",
    -- cjson
    "cjson", "cjson.safe",
    -- 自带 .so / vendored
    "utils", "struct", "rapidjson", "protobuf", "libredis_slot",
    -- 由 init.lua 注入的兼容层（deprecated，新代码不应使用）
    "_G.DMP",
}

globals = {
    -- init.lua 显式挂载的兼容层
    "DMP", "isEmpty", "on", "json_decode", "json_encode", "createIdCookie",
    -- init_worker.lua 读取
    "_G",
}

-- 允许被改写的标准库。
-- 本项目**不再猴补** string / table，但仍需允许插件与 vendored 代码访问，
-- 故此处不设 unused/write restrictions 之外的额外限制。
ignore = {
    "212",  -- unused argument
    "631",  -- line is too long（已由 max_line_length 覆盖）
}

files["spec/"] = {
    std = "+busted",
}
