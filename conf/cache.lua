--- 缓存后端配置。
---
--- 由 `lib/config.lua` 在启动期校验。**键名必须与 `system.vendors` 的数据源名对齐** ——
--- 原版公开精简仓把这里写成 `["redis"] = {...}` 而代码按 source 名（`mz`/`iqy`/`yk`）
--- 查找，导致 `conf.redisCluster["mz"]` 索引 nil 崩溃。本版的校验会把这类
--- 「键名与代码期待不一致」的问题拦在启动阶段。

cache = {

    ------------------------------------------------------------------ 键前缀
    ["order_table"] = "dmp:OrderId:",
    ["service_table"] = "dmp:Service:",
    ["cache_table"] = "dmp:Cache:",

    ------------------------------------------------------------------ 单机 Redis
    --- 身份映射的主存储。
    ["redis"] = {
        ["host"] = "127.0.0.1",
        ["port"] = 6379,

        --- 命令超时（毫秒）。
        --- **原版这里是 20（注释写 ms）** —— 对跨网段 Redis 明显偏紧，
        --- 是 `failed to get key` 间歇性报错与连接池抖动的常见诱因。
        --- 具体取值需按实际 RTT 复核。
        ["timeout_ms"] = 200,

        ["pool_max_idle_time_ms"] = 60000,
        ["pool_size"] = 200,

        --- 数据库下标。声明了就必须真的 select：
        --- 原版接受 db_index 却从不调用 select，属于静默失效。
        ["db_index"] = 0,

        --- AUTH 密码。留空表示无需认证。
        ["password"] = nil,
    },

    ------------------------------------------------------------------ Redis Cluster
    --- 仅在需要跨 slot 时使用。键名必须与 system.vendors 的数据源名一致。
    --- 结构：dataSourceName -> 节点数组
    ["redis_clusters"] = {
        -- ["example"] = {
        --     { host = "10.0.0.1", port = 6379 },
        --     { host = "10.0.0.2", port = 6379 },
        -- },
    },
}

return cache
