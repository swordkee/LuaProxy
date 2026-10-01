--- 数据源凭据与**上游白名单**。
---
--- ## 安全约定
--- `vendors` 与 `upstreams` 里是**服务端可信配置**；调用方只能引用**名字**，
--- 不能提供 host / port / protocol。`lib/upstream.lua` 会强制这一点 ——
--- 这是修复原版 SSRF 漏洞（P0）的核心。
---
--- ## 凭据管理
--- 原版把 7 家厂商的 `KeySecret` / token 明文写在版本库里
--- （`DMP_API/conf/system.lua:6,11-12,16-17,26-27,36,42-43,46-47`）。
--- 正确做法是**只提交模板，真实值由部署时注入**：
---
--- ```bash
--- # conf/system.local.lua 不入库（见 .gitignore），在 init 阶段合并
--- export DMP_SYSTEM_LOCAL=/data/conf/system.local.lua
--- ```
--- 本文件保留占位符，切勿把真实凭据写回来。

system = {

    ------------------------------------------------------------------ 数据源
    --- 每个数据源一份。键名必须与 config.dmp 中的条目一一对应。
    vendors = {

        --- 示例适配器。默认 mock = true，clone 下来即可 curl 出完整结果，
        --- 不需要先搭一个真实上游。
        ["example"] = {
            --- 该数据源面向调用方暴露的标签（可被请求参数 tid 覆盖）
            tagID = "1001,1002,1003,1004,1005,1006",

            --- 上游 uid 对应的 mtype 口径
            upstream_mtype = 'imei_md5',

            --- 通用反代通道使用的**白名单名字**，见下方 upstreams
            upstream = nil,

            --- mock 模式：不发真实请求，按 key 的哈希产出确定性标签。
            --- 置为 false 并配置 upstream 后走真实 HTTP。
            mock = true,

            --- mock 模式下产出的标签数量
            mock_tag_count = 3,

            --- 凭据 —— 走环境变量注入，不要写死
            --- key_id = os.getenv('DMP_EXAMPLE_KEY_ID'),
            --- key_secret = os.getenv('DMP_EXAMPLE_KEY_SECRET'),
        },
    },

    ------------------------------------------------------------------ 上游白名单
    --- `tcp[]` 通用反代通道**唯一**能连接的目标集合。
    ---
    --- 调用方请求形如：
    --- ```json
    --- {"tcp": [{"upstream": "partner", "path": "/v1/query?a=1", "method": "GET"}]}
    --- ```
    --- 而**不是** `{"tcp": [{"host": "10.0.0.1", "port": 8080, ...}]}`。
    ---
    --- 可选字段：
    ---   base_path   —— 请求 path 必须落在此前缀下
    ---   timeout_ms  —— 覆盖全局 httptimeout_ms
    ---   methods     —— 允许的 HTTP 方法，默认 { GET, POST }
    ---   proxy       —— true 表示走 nginx upstream 反代（需在 config.http_proxy 登记）
    ---
    upstreams = {
        -- ["partner"] = {
        --     host = 'partner.example.com',   -- 不允许含 / @ ? # \ 或端口后缀
        --     port = 443,
        --     protocol = 'https',
        --     base_path = '/v1/',
        --     timeout_ms = 800,
        --     methods = { 'GET', 'POST' },
        --     proxy = false,
        -- },
    },

    ------------------------------------------------------------------ 通用
    --- 通用反代请求的参数约束（用于自检与文档）
    ["tcp"] = {
        jsonSchema = '{"type":"object","properties":{'
            .. '"upstream":{"type":"string"},'
            .. '"protocol":{"type":"string","enum":["http","https"]},'
            .. '"port":{"type":"integer"},'
            .. '"method":{"type":"string","enum":["GET","POST"]},'
            .. '"timeout":{"type":"integer"},'
            .. '"path":{"type":"string"},'
            .. '"callBack":{"type":"string"},'
            .. '"proxy":{"type":"boolean"}},'
            .. '"required":["upstream","path"]}'
    },
}

return system
