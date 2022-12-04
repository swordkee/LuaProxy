cassandra = {
    ["keyspace"] = "mapping", --表名
    ["lua_shared_dict"] = "cassandra_lock", --缓存表名
    ["max_schema_consensus_wait"] = 10000,
    ["auth"] = { "cassandra", "cassandra" },
    ["default_port"] = 9042,
    ["timeout_read"] = 2000, --ms
    ["lock_timeout"] = 5, --ms
    ["timeout_connect"] = 1000, --ms
    ["retry_on_timeout"] = false,
    ["ssl"] = false,
    ["verify"] = false,
    ["protocol_version"] = 3, --集群强制为版本3
    ["cassandra"] = {
        ip = { "127.0.0.1" },
        ["redis"] = {
            table = "xxx_dmp",
        },
    }
}


return cassandra