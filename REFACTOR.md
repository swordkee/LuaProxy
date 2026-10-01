# 重构说明

> **范围**：`E:\work\Lua\DMP_API` 公开精简版（github.com/swordkee/LuaProxy）
> **基线**：commit `a357673` "init"
> **日期**：2026-10-01
> **性质**：代码重构。评审依据见 [`../DMP_API/CODE_REVIEW.md`](../DMP_API/CODE_REVIEW.md)

---

## 0. 前置：公开版的三处硬阻断

精简时删掉了 12 个厂商适配器（`api/{mz,ad,nad,td,ntd,gt,iqy,gp,bf,ify,lno,yk}.lua`）
与 `lib/t_socket.lua`，但**没有同步清理引用它们的代码**。结果公开版**根本启动不了**：

| # | 位置 | 问题 |
|---|---|---|
| 1 | `init_worker.lua:2` | `require("api.gt")` —— `api/gt.lua` 已删除。该 require 位于 `init_worker_by_lua`，**所有 worker 起不来** |
| 2 | `conf/config.lua:12` | `dmp` 白名单仍列 12 个模块，全部不存在 → 任何带 `dmp=` 的请求报 module not found |
| 3 | `conf/cache.lua:16` `cassandra.lua:16` | 键名被改成 `"redis"`，但 `t_cache`/`t_cassandra` 按 **source 名**查找 → `conf.redisCluster["mz"]` 索引 nil 崩溃 |

另有 `lib/t_http.lua:52` 相对内网版**是退化的** —— 内网版把连接池按 worker 数折算，
公开版把这行注释掉退回 `conf.pool_size`，8 worker 即 2400 条连接。

凭据与 IP 已彻底脱敏（全部 `127.0.0.1` / `xxx` 占位），这点做得干净。

---

## 1. 重构前的三个判断

在动手前先确认了三件事，避免"改完更糟"：

1. **架构骨架是对的，不推倒。** `t_thread.lua` 的协程扇出是聚合网关的标准解法；
   `conf.dmp` 白名单阻断 `require` 路径穿越的思路也正确。问题全在边界处理与工程规范。
2. **公开版的定位是"可阅读的代码样本"，不是生产系统。** 因此本次不做依赖升级、
   不引入 OpenResty 新特性，保持能在 Lua 5.1 语法下运行。
3. **安全边界的改动必须收敛而非扩散。** SSRF 白名单是唯一的行为破坏性改动，
   单独说明（§3.1）。

---

## 2. 保留的设计

重构不是全盘重写，以下部分原样继承并在注释中标注了原因：

| 设计 | 原位置 | 评价 |
|---|---|---|
| 协程扇出编排 | `t_thread.lua` | 12 个上游压成 1 个 RTT，聚合网关的标准解法 |
| 模块白名单 | `t_thread.lua:13,20` | 阻断 `require` 路径穿越，思路正确 |
| HTTP 双通道 | `t_http.lua` | 直连 + nginx upstream，兼顾性能与 HA |
| 连接池按 worker 折算 | `t_http.lua:52` | 思路正确（`t_mysql` 漏做，本次一并补上） |
| `table.new` 预分配 | `t_redis.lua:8` | LuaJIT 实践正确 |
| shared dict 缓存 token | `gt.lua:17,105` | 用 dict 而非 worker-local 是对的 |
| 统一适配器契约 | `api/*.lua` 的 `M.getInfo` | 12 家异构收敛到同一接口，抽象合理 |
| `used` 耗时埋点意识 | 全局 | 意图好，只是格式未统一 |
| gt 的 token 失效自愈 | `gt.lua:76-78` | 设计意图正确 |

---

## 3. 安全边界改动（唯一破坏性变更）

### 3.1 SSRF —— 上游白名单 ★本次最重要的一处

**原链路**

```lua
-- api.lua:11        args = json_decode(body)              -- 请求体全部由调用方控制
-- t_thread.lua:30   spawn(req.requestHttp, args['tcp'][k])
-- t_http.lua:118    ngx.location.capture('/proxy/' .. host .. path)
-- dmpapi.conf:70    proxy_pass $1://$2;                    -- $2 来自请求体
```

`tcp[].host` / `port` / `path` 全部来自请求体，nginx 用变量拼 `proxy_pass`。
`location /proxy/` 上的 `internal;` **只能阻止外部直接访问该 location，
不能阻止 SSRF** —— 调用方可让 nginx worker 向 `127.0.0.1:9042`、
`169.254.169.254` 或任意内网 host:port 发起请求，等价于一个无鉴权的开放代理。

更糟的是 `conf/config.lua` 里配了 `http_proxy` 反代白名单，
但 `multiRequest.lua` 从未强制校验 —— **白名单形同虚设**。

**新模型**

调用方只提供**名字**，连接目标完全由服务端配置决定：

```lua
upstreams = {
    ['partner'] = {
        host = 'partner.example.com',  -- 唯一可信来源
        port = 443,
        protocol = 'https',
        base_path = '/v1/',            -- 可选
        methods = { 'GET', 'POST' },   -- 可选
    },
}
```

```json
{"tcp": [{"upstream": "partner", "path": "/v1/query?a=1", "method": "GET"}]}
```

`lib/upstream.resolve()` 强制：

| 约束 | 挡住的逃逸 |
|---|---|
| 必须给 `upstream` 名字 | 直接给 host |
| 名字必须在白名单内 | 内网地址探测 |
| **显式拒绝**调用方的 `host`/`port`/`protocol` | 静默忽略会让调用方误以为已生效 |
| path 必须以 `/` 开头且非 `//` | `//evil.com/x` 协议相对 URL |
| path 禁 `://` `..` `@` `%` `#` | 绝对 URL / 路径穿越 / userinfo 注入 / 百分号编码穿越 |
| path 禁控制字符 | CRLF 头注入 |
| 可选 `base_path` 前缀约束（校验分隔符，`/v1evil` 不算在 `/v1/` 下） | 前缀绕过 |
| `GET`/`POST` 白名单 | 任意方法 |

nginx 侧同步收紧：`rewrite` 的 alias 段收紧为 `[A-Za-z0-9_-]+`，
`proxy_next_upstream` 去掉 `http_403 http_404`（4xx 是业务语义而非节点故障），
补 `proxy_ssl_server_name on`。

**验证**：`spec/upstream_spec.lua` 共 30 条断言，每条 `assert.is_nil` 对应一条逃逸路径。

### 3.2 凭据明文 → 模板 + 注入

原版 `conf/system.lua` 硬编码 7 家厂商的 `KeySecret`/`token`，
`build.xml`（内网版）含 15 台生产机 IP 与 Jenkins 私钥路径。

公开版凭据已脱敏，本次在此基础上：

- `conf/system.lua` 改为纯模板，真实值走环境变量
- `.gitignore` 忽略 `conf/*.local.lua`、`*.local.conf`
- 文档注明"进过 git 历史的凭据应视为已泄露、需轮换"

### 3.3 PII 落盘 → 只记摘要

原版 `t_logger.lua:4` 把 `ngx.ctx.msg`（= 完整入参 + 命中结果，
含 IMEI/IDFA/cookie 与人群包标签）以 WARN 写入 error log，无脱敏无保留期。

新 `lib/logger.lua` 只记录聚合摘要（`code= elapsed= sources=[example=200/1ms]`），
并保留 `util.redact` 作为兜底。

### 3.4 TLS 校验

`t_http.lua` 原文 `httpc:ssl_handshake(nil, host, false)` —— 第三个参数 `verify`
写死 `false`，等于关闭证书校验。改为 `true`。

---

## 4. 确定性逻辑缺陷

### 4.1 协程错误被静默吞掉

```lua
-- t_thread.lua:46-51
local ok, info, source, used = ngx.thread.wait(threads[i])
if ok then ... end        -- 协程抛异常时 ok=nil → 该数据源直接从结果中消失
```

新 `orchestrator.runOne` 用 `pcall` 包住 `fetch`，异常转成 500 信封并记日志。
`run` 里对 `wait` 的返回值三分支处理（成功 / `timeout` / 协程体致命错误），
不再有"丢了就丢了"的路径。

### 4.2 超时判定整段被注释

`t_thread.lua:37-44` 的超时循环被完整注释，`conf.TIMEOUT = 20` 成了死配置，
一个卡住的上游会让请求挂到 nginx 默认 60s。

新实现用 `ngx.thread.wait(thread, budget)` + `ngx.thread.kill(thread)`，
双层预算：`source_budget_ms`（单源）与 `request_budget_ms`（全局，
由 `config.load` 校验必须 ≥ source）。

### 4.3 `table.merge` 令同 source 结果互相覆盖 ★

```lua
-- init.lua:78-83
for k, v in pairs(b) do ... else a[k] = v end   -- 数字键直接赋值，不追加
-- nad.lua:2
local source = "ad"     -- 与 ad.lua 撞同一个 source
```

请求 `dmp=ad,nad` 时两个协程都返回 `source="ad"` → 走 `table.merge`
→ **ad 的结果被 nad 整体冲掉**，客户端无感知。

新 `util.deepMerge` 对数组合并语义为**追加**，并按 `util.groupBy` 重组
（同时把原版的 O(n²) 降到 O(n)）。

> 顺带一提：这个 bug 在我自己写的第一版里也复现了 —— 最初把 `dst[k]` 当作
> 待合并的子表，结果 `{'a','b'} + {'c','d'}` 仍然变成 `dst[1]={'c'}, dst[2]={'d'}`。
> 测试把它逼了出来。

### 4.4 `dict:set` 无 TTL

`t_cache.lua` 五处 `dict:set` 全为 2 参数形式。rmid→uid 是人群定向的依据，
"陈旧"直接等于"投错人"，而原版只能等 shared dict 满被 LRU 挤掉。
新实现统一按 `cfg.dict_ttl_ms` 写入，并处理 `set` 返回 false（内存耗尽需告警）。

### 4.5 `mz.lua` 缓存未命中后继续错查

`mz.lua:28-47`：`mtype=="redis"` 但缓存未命中时不返回错误，
继续把原始 rmid 当设备号 `ngx.md5(key)` 发给厂商 → 静默错误结果。

新适配器把"映射缺失"作为独立状态码 `410 IDENTITY_MISS` 返回。

### 4.6 `td.lua` 未知 mtype 默认 IMEI_MD5 但不转换

`td.lua:89-90`：`on(fSwitch, fSwitch(), 178)` 默认 178（IMEI_MD5），
但 `key` **从未做过 MD5 转换** → 明文 IMEI 被标成 MD5 发出去。
新实现在 `normalizeKey` 里穷举分支，未知类型返回 400 而非静默错配。

### 4.7 Redis 连接从不归还（缓存 miss 是最常见分支）

```lua
-- t_redis.lua:199-209
local result, err = fun(redis, ...)
if not result or err then
    return nil, err            -- 既不 keepalive 也不 close
end
if is_redis_null(result) then
    result = nil               -- 也不归还
end
```

DMP 场景 miss 极多，即每次 miss 都新建 TCP 连接并重做 AUTH，池形同虚设。
新 `lib/redis.lua` 用 `settle()` 收口所有出口。

### 4.8 其余确定性 bug

| 原位置 | 问题 | 修正 |
|---|---|---|
| `t_socket.lua:78,101` | `sock.close()` 少冒号 → 错误处理路径自己崩 | `sock:close()` |
| `t_socket.lua:94` | `return null`（未定义全局）→ 下游拼 nil 崩溃 | 返回 `(nil, err)` |
| `apis.lua:37` | `method` 未声明，HMAC 不覆盖 HTTP 方法 | 签名覆盖 method+path+body+nonce+ts |
| `apis.lua:42` | `thr.thread` 传 3 参 vs 接收 1 参 → `pairs(string)` 抛错 | 签名一致 |
| `api.lua:11` | 只用 `get_body_data()`，超 8k 请求体误判 bad request | 回退读 `get_body_file()` |
| `api.lua:24` | `json_encode` 返回值未判空 → `ngx.say(nil)` 抛错 | 兜底字面量 |
| `dmpapi.lua:15,19` | 业务错误也返回 HTTP 200 | 按语义映射 400/403/502 |
| `t_cache.lua:52-70` | `getRedisByZset` 三次往返无事务 | `ZPOPMIN` 或 Lua 脚本 |
| `t_cache.lua:156` | `return ok`（未定义全局） | 返回统计信息 |
| `t_mysql.lua:35` | 池容量未除 worker 数 | 统一折算 |
| `t_cassandra.lua:10-28` | 每次请求 `cluster.new()` → README 的"首次请求慢" | 按 worker 缓存 |
| `init.lua:184` | `call_user_func` 的 `t == "string "` 多空格 + 记日志后照样崩 | 移除（已无调用方） |

---

## 5. 工程规范

### 5.1 清理死代码

原版 `conf/dmpapi.conf` 里 `/apis`、`/check`、`/a.gif`、`/redis`、`/scylla`
五个 location **全部被注释**，对应的 5 个 `plugins/` 目录却仍在仓库里，
且 `build.xml`（内网版）的 `<include name="*"/>` 会把它们打包部署到全部生产机。

其中 `plugins/scylla` 依赖 `lib.t_cassandra`、`plugins/RedisCluster` 依赖
`lib.t_redis`、`plugins/multi` 依赖 `lib.t_mysql` —— 在本次删除旧 lib 后
已成悬空引用。已连同 `lib/t_mysql.lua` 一并移除。

同理删除 `lib/t_socket.lua`：它承载的 TCP / Protobuf 通道（腾讯 `xdmp.l.qq.com`
私有协议）在精简版中已无任何调用方，且其中的 `sock.close()` / `return null`
等问题需要整条链路才能修复。保留一个无调用方且已知有缺陷的模块，不如删掉。

### 5.2 启动期配置校验

原版 `conf/*.lua` 是裸表，key 拼错要等线上第一次请求命中该分支才暴露，
且错误是 `attempt to index a nil value`，完全没有线索指向配置。

新 `lib/config.lua` 在 `init_by_lua` 一次性校验并**一次性报出全部问题**：

```
config[system] 校验未通过，共 2 项:
  1. system.upstreams.partner.host 含非法字符: evil.com:6379/
  2. config.dmp 声明了数据源 "ghost"，但 system.vendors.ghost 缺失
```

覆盖：类型、正数、单位后缀、跨字段一致性（`request_budget ≥ source_budget`）、
白名单键名对齐（Cassandra 表名必须是纯标识符，因为 CQL 不支持占位符绑定表名）。

### 5.3 适配器契约校验

`require` 从热路径移到启动期（`lib/dispatch.lua`），
并校验 `name` 与 `fetch` 存在。不合规直接拒绝启动。

### 5.4 统一响应契约

原版 `code` 在不同适配器含义不同，`used` 有 4 种格式（`-2` / `0|-2` / `123` / `12|34`），
`result` 有时是数组有时是字符串，调用方无法写通用逻辑。

新 `lib/envelope.lua` 定义 12 个语义唯一的码，`result` 恒为数组。
`env.fromLegacy` 提供渐进迁移通道。

### 5.5 消除全局污染

原版 `init.lua` 猴补 `string.split/trim` 与
`table.len/merge/unique/findkeys/invert`，并注入 `isEmpty`/`on`/`json_decode` 等全局。

新版本收进 `lib/util.lua`（纯函数，可脱离 OpenResty 测试）与 `lib/ngx_ext.lua`。
`init.lua` 保留同名全局作为 **deprecated 薄封装**，让既有调用方不必立刻改。

顺带修掉 `isEmpty` 的口径坑：原版 number 分支把 `0` 判为"空"
（`(str == 0 and {true} or {false})[1]`），且每次调用额外分配两个 table。
新 `isBlank` 数字永不算空，且是 O(1)。

### 5.6 测试与静态检查

新增 `spec/`（5 个文件，约 120 条断言）与 `.luacheckrc`。
详见 README「开发」一节 —— 那里列出了 luacheck 能直接报出的原版缺陷。

---

## 6. 未做的事

明确划出范围，避免"顺手"扩大影响面：

| 项 | 原因 |
|---|---|
| **vendored `resty/` 升级或去重** | 属第三方代码；升级 OpenResty 后若忘记重拷就是静默行为变更，需单独评估并加版本钉 |
| **新增 CI** | 仓库无 CI 基础设施，需先确认托管与流水线要求 |
| **busted / luacheck 实跑** | 本机无 luarocks，改用等价 runner 验证（结果见下） |
| **依赖版本升级** | 保持 Lua 5.1 语法 |

---

## 7. 验证结果

```
# 1. 语法编译（luajit -bl 逐文件，26 个文件）
ALL FILES COMPILE OK

# 2. 纯函数单元测试  util / envelope / upstream(SSRF) / orchestrator
PASS: 102   FAIL: 0

# 3. 配置启动期校验测试  config.load
PASS:  16   FAIL: 0

# 4. 集成自检  require 链 / 导出契约 / normalizeKey / mock 路径 /
#             buildTcpSpecs / multi_request 拒绝 / redact 端到端
PASS:  74   FAIL: 0
                                          ─────────
                                   合计 192 条断言全部通过
```

第 2、3 组与 `spec/` 下的 busted 用例一一对应；第 4 组因需要 ngx 运行时
（`ngx.timer` / `ngx.shared` / `ngx.location.capture`）在纯 luajit 下不可跑，
用 ngx 桩验证了模块加载链与关键分支。

`busted` 与 `luacheck` 因本机无 luarocks 未执行，spec 文件已按 busted 语法编写，
可在有运行时的环境直接跑：

```bash
busted && luacheck .
```

**尚未验证的部分**（需要真实 OpenResty 环境）：
`init.lua` 的启动流程、`init_worker.lua` 的定时器注册、
`orchestrator.run` 的协程超时与 kill、`lib/http.lua` 的真实连接池行为、
nginx 配置语法（`nginx -t`）。

---

## 8. 文件对照

| 原文件 | 现状 |
|---|---|
| `init.lua` | 重写：配置校验 + 适配器注册 + 常量预计算 |
| `init_worker.lua` | 重写：不再 require 已删除的 `api.gt`（原阻断点 #1） |
| `api.lua`（原 `dmpapi.lua`） | 重写：方法校验、body 兜底、状态码映射、脱敏摘要 |
| `apis.lua` | 重写：签名覆盖 method+path+body+nonce+ts，常量时间比较 |
| `lib/t_thread.lua` | → `lib/orchestrator.lua` |
| `lib/t_http.lua` | → `lib/http.lua` |
| `lib/t_redis.lua` | → `lib/redis.lua` |
| `lib/t_cache.lua` | → `lib/cache.lua` |
| `lib/t_cassandra.lua` | → `lib/cassandra.lua` |
| `lib/t_logger.lua` | → `lib/logger.lua` |
| `lib/t_mysql.lua` | 已删除（唯一调用方是已删除的 `plugins/multi`） |
| `lib/t_socket.lua` | 已删除（连同 TCP / Protobuf 通道） |
| `plugins/`（5 个目录） | 已删除。全部在原 nginx conf 中被注释（死代码），且引用已删除的 `lib.t_redis` / `lib.t_cassandra` / `lib.t_mysql` |
| `api/multiRequest.lua` | → `api/multi_request.lua` |
| `api/{12 个厂商}.lua` | 已删除 → 新增 `api/example.lua` 作为模板 |
| — | 新增 `lib/util.lua` `lib/ngx_ext.lua` `lib/envelope.lua` `lib/config.lua` `lib/dispatch.lua` `lib/upstream.lua` |
| — | 新增 `spec/` `.busted` `.luacheckrc` `.gitignore` `README.md` `REFACTOR.md` |
| `conf/*.lua` | 重写：单位后缀、键名对齐、模板化凭据 |
| `conf/dmpapi.conf` | 重写：限流、body 上限、SSRF 侧收紧、TLS、SNI |
| `resty/` | 未动（第三方 vendored） |
