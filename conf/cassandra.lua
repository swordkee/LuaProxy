--- Cassandra 配置（`cache_type = 'cassandra'` 时生效）。
---
--- 键名必须与 `system.vendors` 的数据源名对齐 —— 由 `lib/config.lua` 在启动期校验。
---
--- ## 关于连接复用
--- 原版 `t_cassandra.lua:10-28` 在**每次请求**里 `cluster.new()`，
--- 每次都要重新做 contact_points 协商（`max_schema_consensus_wait = 10000`）。
--- 这正是 README 里那条「已知问题：第一次请求比较慢」的成因。
--- 本版在 `lib/cassandra.lua` 中按 worker 缓存 cluster 实例。

cassandra = {

    ["keyspace"] = "mapping",
    ["lua_shared_dict"] = "cassandra_lock",

    --- 连接认证。
    --- **原版这里是 { "cassandra", "cassandra" } 默认弱口令，且明文入库。**
    --- 若生产也在用同一组默认口令，属独立的安全事件，需轮换。
    ["auth"] = { "cassandra", "CHANGE_ME" },

    ["default_port"] = 9042,

    ["timeout_read_ms"] = 2000,
    ["timeout_connect_ms"] = 1000,
    ["lock_timeout_ms"] = 5,

    ["retry_on_timeout"] = false,
    ["ssl"] = false,
    ["verify"] = false,
    ["protocol_version"] = 3,

    ------------------------------------------------------------------ contact points
    ["ip"] = { "127.0.0.1" },

    ------------------------------------------------------------------ 表映射
    --- 数据源名 -> { table = '...' }
    --- `table` 必须是纯标识符（仅字母/数字/下划线）—— CQL 不支持占位符绑定表名，
    --- 这一点由 lib/config.lua 强制校验，杜绝拼接注入。
    ["vendors"] = {
        -- ["example"] = {
        --     table = "example_dmp",
        -- },
    },
}

return cassandra
