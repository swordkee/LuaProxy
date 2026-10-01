# LuaProxy

基于 **OpenResty / LuaJIT** 的 DMP（广告人群定向）聚合网关。

一次请求携带多个数据源，由服务端并发扇出到各厂商接口，再统一归并返回：

```json
{"dmp": "example", "key": "8D6A13B7FE90BBE6079AE1D91159E387", "mtype": "imei_md5"}
```

---

## 这是什么

本项目最初写于 2017 年（`DMP_API`），本次在其公开精简版基础上做了**一次针对性重构**。
重构范围与每一处的依据，见 [`REFACTOR.md`](REFACTOR.md)；原代码的完整评审见
[`../DMP_API/CODE_REVIEW.md`](../DMP_API/CODE_REVIEW.md)。

重构集中在三类问题：

| 类别 | 代表问题 |
|---|---|
| **安全边界缺失** | `tcp[]` 的 host/port 直接进 `proxy_pass $1://$2` → 无鉴权的内网探测器（SSRF）；凭据明文入库 |
| **确定性逻辑错误** | 协程错误被静默吞掉；超时判定整段被注释；`table.merge` 令同 source 结果互相覆盖；`dict:set` 无 TTL |
| **工程规范空白** | 无配置校验、无测试、无静态检查、无 `.gitignore`、全局猴补 `string`/`table` |

---

## 快速开始

### 依赖

- OpenResty（需 `--with-luajit`）
- 可选：`redis` / `lua-resty-redis-cluster` / `pbc` / `struct`（取决于启用的数据源）

### 安装

```bash
# 1. 代码部署到 webapps
mkdir -p /data/modules/openresty/webapps
ln -s /path/to/LuaProxy /data/modules/openresty/webapps

# 2. vendored 第三方库
cd /data/modules/openresty/webapps
cp resty/http.lua resty/http_headers.lua resty/rediscluster.lua \
   resty/rfc5424.lua resty/dump.lua resty/logger/socket.lua \
   /data/modules/openresty/lualib/resty/
cp -rp resty/cassandra/ /data/modules/openresty/lualib/resty/
cp resty/cassandra/cassandra/ /data/modules/openresty/lualib/
cp resty/so/protobuf_c.so resty/so/struct.so resty/so/utils.so \
   resty/so/rapidjson.so /data/modules/openresty/lualib/
cp resty/so/libredis_slot.so /data/modules/openresty/luajit/lib/lua/5.1/

# 3. nginx 配置
cp conf/dmpapi.conf /data/modules/openresty/nginx/conf/vhosts/

# 4. 校验并启动 —— 配置错误会在这里直接拒绝启动
nginx -t && nginx -s reload
```

> `conf/dmpapi.conf` 里 `init_by_lua_file` 指向 `init.lua`。该文件会做完整的配置校验，
> 任何一项不合法都会让 `nginx -t` 失败并打印**具体是哪一项**——
> 这是本次重构的重点之一（见 REFACTOR.md §3）。

### 验证

clone 下来即可自测：`api/example.lua` 默认 `mock = true`，不发真实请求，
按 key 的哈希产出确定性标签。

```bash
# 单数据源
curl -s http://127.0.0.1:8083/api -d '{
  "dmp": "example",
  "key": "8D6A13B7FE90BBE6079AE1D91159E387",
  "mtype": "imei_md5"
}'
```

```json
{
  "sources": { "example": ["tag_3f", "tag_a7"] },
  "code": 200,
  "codes": { "example": 200 },
  "elapsed": 1
}
```

```bash
# 通用反代通道（host 来自服务端白名单，调用方只给名字）
curl -s http://127.0.0.1:8083/api -d '{
  "tcp": [{ "upstream": "partner", "path": "/v1/query?a=1", "method": "GET" }]
}'

# 健康检查
curl -s http://127.0.0.1:8083/healthz

# 排障（返回已注册的数据源与上游、配置告警）
curl -s http://127.0.0.1:8083/_dmp/status
```

---

## 架构

```
请求 ──► api.lua ──► orchestrator ──┬──► api/<source>.fetch()   (并发)
                                    └──► api/multi_request       (并发)
                                              │
                                              ▼
                                    envelope 统一归一
                                              │
                                              ▼
                                    lib/logger.lua 落脱敏摘要
```

| 模块 | 职责 |
|---|---|
| `init.lua` | 启动期：配置校验 → 适配器注册 → 常量预计算。结果存入 `_G.DMP` |
| `init_worker.lua` | 每 worker：播种随机源、注册周期任务、预热缓存 |
| `lib/config.lua` | 配置装载与校验，**一次性报出全部问题** |
| `lib/dispatch.lua` | 适配器注册表，`require` 与契约校验都在启动期完成 |
| `lib/orchestrator.lua` | 协程扇出、限时收割、结果归并 |
| `lib/envelope.lua` | 统一响应信封与状态码契约 |
| `lib/upstream.lua` | **上游白名单**（SSRF 防护） |
| `lib/http.lua` | HTTP 客户端（直连 / nginx 反代双通道） |
| `lib/redis.lua` `lib/cache.lua` | Redis 客户端与身份映射缓存 |
| `lib/cassandra.lua` | Cassandra 客户端（按 worker 缓存连接） |
| `lib/util.lua` `lib/ngx_ext.lua` | 纯函数工具 / ngx 相关辅助 |
| `lib/logger.lua` | 排障摘要落盘（已脱敏） |

---

## 新增一个数据源

1. 复制 `api/example.lua`，改 `name` 与上游交互部分；
2. 在 `conf/config.lua` 的 `dmp` 里加上名字；
3. 在 `conf/system.lua` 的 `vendors.<name>` 填凭据与默认标签；
4. 若走通用反代，在 `system.upstreams` 登记并按需设 `proxy = true`；
5. `nginx -t && nginx -s reload`。

**契约**：`fetch(self, params, budget_ms)` 返回 `env.hit(tags, elapsed)` 或
`env.fail(code, detail)`。抛异常也可以 —— orchestrator 会 `pcall` 并转成 500，
不会污染其他数据源。

```lua
local env = require('lib.envelope')
local http = require('lib.http')
local upstream = require('lib.upstream')

return {
    name = 'myvendor',
    version = '1.0',

    fetch = function(self, params, budgetMs)
        local spec, err = upstream.resolve({
            upstream = 'partner',
            method  = 'POST',
            path    = '/query',
            data    = require('lib.ngx_ext').jsonEncode({ uid = params.key }),
        }, _G.DMP.cfg, _G.DMP.cfg.max_body_bytes)
        if spec == nil then
            return env.fail(env.CODES.INTERNAL, err)
        end

        local status, body = http.send(spec, _G.DMP.cfg)
        if status ~= 200 then
            return env.fail(env.CODES.UPSTREAM_UNAVAILABLE, 'upstream ' .. tostring(status))
        end

        local payload = require('lib.ngx_ext').jsonDecode(body)
        local tags = {}
        for id, hit in pairs(payload or {}) do
            if hit == 1 then tags[#tags + 1] = id end
        end
        return env.hit(tags, 0)
    end,
}
```

如需定时刷新厂商 token，实现 `refresh()` 并登记到 `conf.config.refreshers`。

---

## 安全约定

### 凭据

**不要把真实凭据提交到版本库。** `conf/*.lua` 只提交模板，
真实值由部署时注入（见 `.gitignore` 中的 `conf/*.local.lua`）：

```bash
export DMP_EXAMPLE_KEY_ID=...
export DMP_EXAMPLE_KEY_SECRET=...
```

原版把 7 家厂商的 `KeySecret` / token 明文入库 —— 这类值一旦进过 git 历史，
就应视为已泄露、需要轮换，而不只是从当前版本删掉。

### 上游白名单

`tcp[]` 通道**不接受调用方提供的 host/port/protocol**，只接受在
`conf/system.lua` 的 `upstreams` 中登记的**名字**：

```json
{"tcp": [{"upstream": "partner", "path": "/v1/query?a=1"}]}     // ✅
{"tcp": [{"host": "127.0.0.1", "port": 9042, "path": "/"}]}      // ❌ 403
```

`path` 仍由调用方控制（这是"代理"这一业务形态的固有需要），因此额外校验：
必须以 `/` 开头、不得含 `://` / `..` / `@` / `%` / `#` / 控制字符。
详见 `lib/upstream.lua` 文件头 —— 那里解释了为什么 `internal;` 挡不住 SSRF。

### 日志

日志只记录**聚合摘要**（命中了哪些数据源、各自状态码与耗时），
不记录原始入参与命中标签。设备标识类字段另有 `util.redact` 兜底脱敏。

原版把完整 IMEI/IDFA/cookie 与人群包标签以 WARN 级别写入 error log，
无脱敏、无保留期 —— 叠加 access log 即构成一条完整的设备指纹审计轨迹。

---

## 开发

```bash
# 单元测试
luarocks install busted
busted

# 静态检查
luarocks install luacheck
luacheck .
```

`.luacheckrc` 的价值在于能直接报出原版那类「肉眼极难发现」的缺陷：

| 原版位置 | 问题 | luacheck |
|---|---|---|
| `t_socket.lua:78,101` | `sock.close()` 少一个冒号 | ✅ undefined global / 语法 |
| `t_socket.lua:94` | `return null` —— `null` 是未定义全局 | ✅ undefined variable |
| `t_cache.lua:156` | `return ok` —— `ok` 是未定义全局 | ✅ undefined variable |
| `apis.lua:37` | `method` 未声明，取全局 nil | ✅ undefined variable |
| `t_thread.lua:40` | 超时逻辑整段被注释，从未执行 | ❌ 需靠测试 |
| `nad.lua:2` | `source = "ad"` 与 `ad.lua` 撞名 | ❌ 需靠测试 |

> **这也解释了为什么这些缺陷能存活 9 年** —— 没有一条门禁会发现
> 「一行 `sock.close()` 少了个冒号」。

---

## 许可

见原仓库。`resty/` 下为 vendored 第三方代码，不在本项目维护范围内。
