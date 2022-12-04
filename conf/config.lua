config = {
    DEBUG = true,
    JSONSCHEMA = true,
    _VERSION = '0.06',
    TIMEOUT = 20,
    ["httptimeout"] = 20, --http超时,ms
    ["socktimeout"] = 20, --socket超时,ms
    ["mysqltimeout"] = 1000, --mysql超时,ms
    ["pool_max_idle_time"] = 0, --连接池时长毫秒,0为不超时
    ["pool_size"] = 300, --连接池总数量
    ["delay"] = 7000, --定时器间隔，s
    ["dmp"] = { "mz", "ad", "nad", "td", "ntd", "gt", "iqy", "gp", "bf", "ify", "lno", "yk" },
    ["pbpath"] = "/data/modules/openresty/webapps/resty/",
    ["cache_type"] = "cassandra", --redis,cassandra
    ["log_format"] = "file", --file,rsyslog
    ["http_proxy"] = {
        -- upstream反向代理
        ["mz_proxy"] = 'xxxx.xxxx.com',
    },
    ["rsyslog"] = {
        ["sock_type"] = 'tcp', --连接池总数量
        ["ip"] = "127.0.0.1",
        ["port"] = 514
    },
}

return config