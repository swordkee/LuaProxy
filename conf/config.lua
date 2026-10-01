--- 主配置。
---
--- 所有超时一律带 `_ms` / `_s` 单位后缀。
--- 原版 `httptimeout = 20` 注释写「ms」但全链路按 ms 使用，
--- 20ms 对跨网段上游明显偏紧且语义模糊 —— 此处拆分为语义明确的四个值。
---
--- 本文件由 `lib/config.lua` 在启动期逐项校验，任何不合法都会让 nginx 拒绝启动。

config = {
    --- 调试开关。**生产必须为 false。**
    --- 原版默认值就是 true，且随默认配置一起发布。
    DEBUG = false,

    --- 日志去向：file（error_log）/ rsyslog / none
    log_format = 'file',

    --- 日志中是否记录脱敏后的请求摘要
    log_request_summary = true,

    _VERSION = '2.0',

    ------------------------------------------------------------------ 超时
    --- 单次上游 HTTP 读写的总超时
    ["httptimeout_ms"] = 800,

    --- 建立 TCP/TLS 连接的超时。独立于读写超时：
    --- 连接不通和连接后读不动是两回事，混成一个值无法定位问题。
    ["connect_timeout_ms"] = 300,

    --- 单个数据源的时间预算。超过即判 504 并继续，不拖累其他数据源。
    --- 原版的 `TIMEOUT = 20` 判定逻辑被整段注释，实际从未生效。
    ["source_budget_ms"] = 900,

    --- 单次请求的总预算（必须 >= source_budget_ms，由 lib/config.lua 校验）
    ["request_budget_ms"] = 1200,

    --- MySQL 超时
    ["mysqltimeout_ms"] = 1000,

    ------------------------------------------------------------------ 连接池
    --- 全局池上限。会按 worker 数折算到每个 worker。
    --- 原版 t_http 忘了折算（公开版甚至把折算行注释掉了），
    --- 8 worker × 300 = 2400 条连接。
    ["pool_size"] = 300,

    --- 连接空闲存活时间（毫秒）。0 表示不限。
    ["pool_max_idle_time_ms"] = 60000,

    ------------------------------------------------------------------ TLS
    --- 是否校验上游证书链。
    --- **默认 true，不要为了「排查握手失败」而关掉。**
    --- 原版 t_http.lua 写死 ssl_handshake(nil, host, false) —— 等于关闭校验。
    ["ssl_verify"] = true,

    ------------------------------------------------------------------ 缓存
    --- 身份映射在 shared dict 中的存活时间。
    --- **原版完全没有 TTL** —— rmid -> uid 的映射是人群定向的依据，
    --- 「陈旧」直接等于「投错人」，而原版只能等 dict 满了被 LRU 挤掉。
    ["dict_ttl_ms"] = 300000,

    --- 启动时预热映射的条数上限（每个数据源）
    ["warmup_limit"] = 1000,

    --- 是否在 worker 启动时预热。
    --- 原版是**每个 worker 每 7 秒全量扫描一次**，N 个 worker 就是 N 倍重复 IO。
    ["warmup_on_boot"] = false,

    --- 需要预热的数据源；为空则用 dmp 列表
    ["warmup_sources"] = {},

    ------------------------------------------------------------------ 映射来源
    --- redis / cassandra
    cache_type = 'redis',

    ------------------------------------------------------------------ 请求限制
    --- 请求体上限（字节）。需与 nginx 的 client_max_body_size 保持一致或更小。
    ["max_body_bytes"] = 65536,

    ------------------------------------------------------------------ 周期任务
    --- 需要定时 refresh() 的数据源。适配器必须实现 `refresh()`。
    --- 空数组 = 不启用任何定时任务。
    ["refreshers"] = {},

    --- 刷新间隔（毫秒）
    ["refresh_interval_ms"] = 600000,

    ------------------------------------------------------------------ 数据源
    --- 已实现的数据源列表。每一项都必须满足：
    ---   * conf/system.lua 的 `vendors.<name>` 存在
    ---   * api/<name>.lua 存在且导出 `{ name=, fetch=function(self, params, budget_ms) }`
    --- 两者缺一都会在启动时报错。
    ["dmp"] = { "example" },

    ------------------------------------------------------------------ 反代通道
    --- nginx upstream 的别名 -> 目标 host。
    --- 标记 `proxy = true` 的数据源会经由此表走 `ngx.location.capture`。
    ["http_proxy"] = {
        -- ["partner_proxy"] = 'partner.example.com',
    },

    ------------------------------------------------------------------ 日志
    ["rsyslog"] = {
        ["sock_type"] = 'tcp',
        ["ip"] = "127.0.0.1",
        ["port"] = 514,
        ["flush_limit"] = 1,
        ["drop_limit"] = 5678,
    },

    --- protobuf 描述文件目录
    ["pbpath"] = "/data/modules/openresty/webapps/resty/",
}

return config
