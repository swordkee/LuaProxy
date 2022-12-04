cache = {
    ["orderTable"] = "swordkee:OrderId:", --缓存表名
    ["serviceTable"] = "swordkee:Service:", --缓存表名
    ["cacheTable"] = "swordkee:Cache:", --缓存表名
    ["redis"] = {
        ["timeout"] = 20, --socket超时,ms
        ["pool_max_idle_time"] = 0, --连接池时长毫秒,0为不超时
        ["pool_size"] = 1000, --连接池总数量
        ["ip"] = "127.0.0.1",
        ["port"] = 6379
    },
    ["redisCluster"] = {
        ["timeout"] = 20, --socket超时,ms
        ["pool_max_idle_time"] = 0, --连接池时长毫秒,0为不超时
        ["pool_size"] = 1000, --连接池总数量
        ["redis"] = {
            { ip = "127.0.0.1", port = 6379 },
        }
    }
}

return cache