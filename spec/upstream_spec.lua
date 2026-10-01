--- `lib/upstream` 单元测试 —— SSRF 防护的核心验证。
---
--- 这些用例直接对应评审文档里的 P0-1：调用方原本可以把任意 host/port
--- 塞进 `tcp[]`，经 `proxy_pass $1://$2` 变成无鉴权的内网探测器。
--- 每一条 "assert.is_nil" 都是在封死一条逃逸路径。

local upstream = require('lib.upstream')

--- 构造一份最小可用的 cfg。
--- @param overrides table|nil 覆盖 upstreams 字段
--- @return table
local function makeCfg(overrides)
    return {
        httptimeout_ms = 800,
        max_body_bytes = 65536,
        upstreams = overrides or {
            partner = {
                host = 'partner.example.com',
                port = 443,
                protocol = 'https',
            },
        },
        http_proxy = {},
        http_proxy_reverse = {},
    }
end

describe('upstream.resolve —— 白名单', function()
    it('accepts a registered name', function()
        local spec = upstream.resolve({ upstream = 'partner', path = '/v1/a' }, makeCfg(), 65536)
        assert.is_table(spec)
        assert.equals('partner', spec.name)
        assert.equals('partner.example.com', spec.host)
        assert.equals(443, spec.port)
        assert.equals('https', spec.protocol)
    end)

    it('REJECTS an unregistered name', function()
        local spec, err = upstream.resolve(
            { upstream = 'evil', path = '/x' }, makeCfg(), 65536)
        assert.is_nil(spec)
        assert.is_truthy(err:find('not registered', 1, true))
    end)

    it('requires the upstream field', function()
        local spec, err = upstream.resolve({ path = '/x' }, makeCfg(), 65536)
        assert.is_nil(spec)
        assert.is_truthy(err:find('upstream', 1, true))
    end)
end)

describe('upstream.resolve —— 调用方不得指定连接目标', function()
    it('REJECTS a caller-supplied host', function()
        -- 这是 SSRF 的直接形态：调用方想让网关去连内网地址
        local spec, err = upstream.resolve(
            { upstream = 'partner', host = '127.0.0.1', path = '/x' }, makeCfg(), 65536)
        assert.is_nil(spec)
        assert.is_truthy(err:find('not accepted', 1, true))
    end)

    it('REJECTS a caller-supplied port', function()
        local spec = upstream.resolve(
            { upstream = 'partner', port = 9042, path = '/x' }, makeCfg(), 65536)
        assert.is_nil(spec)
    end)

    it('REJECTS a caller-supplied protocol', function()
        local spec = upstream.resolve(
            { upstream = 'partner', protocol = 'http', path = '/x' }, makeCfg(), 65536)
        assert.is_nil(spec)
    end)
end)

describe('upstream.resolve —— path 逃逸防护', function()
    local function reject(path)
        local spec, err = upstream.resolve(
            { upstream = 'partner', path = path }, makeCfg(), 65536)
        return spec, err
    end

    it('REJECTS protocol-relative URLs', function()
        -- `//evil.com/x` 在 proxy_pass 语境下会指向 evil.com
        local spec, err = reject('//evil.com/x')
        assert.is_nil(spec)
        assert.is_truthy(err:find('must not start with //', 1, true))
    end)

    it('REJECTS absolute URLs', function()
        assert.is_nil(reject('http://evil.com/x'))
    end)

    it('REJECTS path traversal', function()
        assert.is_nil(reject('/v1/../../etc/passwd'))
    end)

    it('REJECTS percent-encoded traversal', function()
        assert.is_nil(reject('/v1/%2e%2e/%2e%2e/etc/passwd'))
    end)

    it('REJECTS userinfo injection', function()
        assert.is_nil(reject('/v1@evil.com'))
    end)

    it('REJECTS fragment', function()
        assert.is_nil(reject('/v1#@evil.com'))
    end)

    it('REJECTS a relative path', function()
        assert.is_nil(reject('v1/a'))
    end)

    it('REJECTS an empty path', function()
        assert.is_nil(reject(''))
    end)

    it('ACCEPTS a normal path with a query string', function()
        local spec = upstream.resolve(
            { upstream = 'partner', path = '/v1/query?a=1&b=2' }, makeCfg(), 65536)
        assert.is_table(spec)
        assert.equals('/v1/query?a=1&b=2', spec.path)
    end)
end)

describe('upstream.resolve —— base_path 约束', function()
    local cfg = makeCfg({
        scoped = {
            host = 'scoped.example.com',
            port = 443,
            protocol = 'https',
            base_path = '/v1/',
        },
    })

    it('accepts paths under the prefix', function()
        assert.is_table(upstream.resolve(
            { upstream = 'scoped', path = '/v1/a' }, cfg, 65536))
    end)

    it('accepts the prefix itself', function()
        assert.is_table(upstream.resolve(
            { upstream = 'scoped', path = '/v1/' }, cfg, 65536))
    end)

    it('REJECTS a sibling path with the same prefix text', function()
        -- /v1evil 不应被当成 /v1/ 之下
        assert.is_nil(upstream.resolve({ upstream = 'scoped', path = '/v1evil' }, cfg, 65536))
    end)

    it('REJECTS paths outside the prefix', function()
        assert.is_nil(upstream.resolve({ upstream = 'scoped', path = '/v2/a' }, cfg, 65536))
    end)
end)

describe('upstream.resolve —— method / body', function()
    it('defaults to GET', function()
        local spec = upstream.resolve({ upstream = 'partner', path = '/x' }, makeCfg(), 65536)
        assert.equals('GET', spec.method)
    end)

    it('normalises to upper case', function()
        local spec = upstream.resolve(
            { upstream = 'partner', path = '/x', method = 'post', data = '{}' },
            makeCfg(), 65536)
        assert.equals('POST', spec.method)
    end)

    it('REJECTS unsupported methods', function()
        local spec, err = upstream.resolve(
            { upstream = 'partner', path = '/x', method = 'DELETE' }, makeCfg(), 65536)
        assert.is_nil(spec)
        assert.is_truthy(err:find('only GET / POST', 1, true))
    end)

    it('requires data for POST', function()
        assert.is_nil(upstream.resolve(
            { upstream = 'partner', path = '/x', method = 'POST' }, makeCfg(), 65536))
    end)

    it('rejects oversized body', function()
        local spec, err = upstream.resolve(
            { upstream = 'partner', path = '/x', method = 'POST', data = string.rep('a', 100) },
            makeCfg(), 10)
        assert.is_nil(spec)
        assert.is_truthy(err:find('too large', 1, true))
    end)

    it('honours a per-upstream method allowlist', function()
        local cfg = makeCfg({
            readonly = {
                host = 'ro.example.com', port = 443, protocol = 'https',
                methods = { 'GET' },
            },
        })
        assert.is_table(upstream.resolve(
            { upstream = 'readonly', path = '/x' }, cfg, 65536))
        assert.is_nil(upstream.resolve(
            { upstream = 'readonly', path = '/x', method = 'POST', data = '{}' }, cfg, 65536))
    end)
end)

describe('upstream.resolve —— 入参类型', function()
    it('rejects a non-table entry', function()
        assert.is_nil(upstream.resolve('nope', makeCfg(), 65536))
    end)

    it('rejects a non-string upstream name', function()
        assert.is_nil(upstream.resolve({ upstream = 123, path = '/x' }, makeCfg(), 65536))
    end)
end)
