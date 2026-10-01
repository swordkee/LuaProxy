--- `lib/config` 单元测试。
---
--- 这些用例验证的是原版最缺的一环：**配置错误必须在启动期暴露**。
--- 原版所有 conf 都是裸表，键名拼错要等线上第一次请求命中该分支
--- 才会以 `attempt to index a nil value` 报错，且没有任何线索指向配置。
---
--- 用例通过替换 package.loaded 注入伪造配置，不触碰真实 conf 文件。

local config = require('lib.config')

--- 装入一份合法的配置，返回其 cfg。
--- @return table
local function validFixtures()
    package.loaded['conf.config'] = {
        DEBUG = false,
        log_format = 'file',
        httptimeout_ms = 800,
        connect_timeout_ms = 300,
        source_budget_ms = 900,
        request_budget_ms = 1200,
        mysqltimeout_ms = 1000,
        pool_size = 300,
        pool_max_idle_time_ms = 60000,
        dict_ttl_ms = 300000,
        max_body_bytes = 65536,
        dmp = { 'example' },
        http_proxy = {},
        rsyslog = {},
    }
    package.loaded['conf.system'] = {
        upstreams = {},
        vendors = { example = {} },
    }
    package.loaded['conf.cache'] = {
        order_table = 'dmp:OrderId:',
        service_table = 'dmp:Service:',
        redis = { host = '127.0.0.1', port = 6379, timeout_ms = 200, pool_size = 200 },
        redis_clusters = {},
    }
    package.loaded['conf.cassandra'] = {
        vendors = {},
    }
    return config.load()
end

--- 清掉所有被测试污染的缓存。
local function clearFixtures()
    for _, name in ipairs({
        'conf.config', 'conf.system', 'conf.cache', 'conf.cassandra',
    }) do
        package.loaded[name] = nil
    end
end

describe('config.load —— 合法配置', function()
    it('loads successfully', function()
        clearFixtures()
        local cfg = validFixtures()
        assert.is_table(cfg)
        assert.same({ 'example' }, cfg.dmp)
        assert.equals(300000, cfg.dict_ttl_ms)
        clearFixtures()
    end)

    it('precomputes http_proxy reverse map', function()
        clearFixtures()
        local loaded = config.load()
        package.loaded['conf.config'].http_proxy = { partner_proxy = 'p.example.com' }
        local cfg = config.load()
        assert.equals('partner_proxy', cfg.http_proxy_reverse['p.example.com'])
        clearFixtures()
    end)
end)

describe('config.load —— 拒绝非法配置', function()
    it('rejects a missing required key', function()
        clearFixtures()
        package.loaded['conf.config'] = nil
        local cfg, err = config.load()
        assert.is_nil(cfg)
        assert.is_truthy(tostring(err):find('配置', 1, true) or tostring(err):find('config', 1, true))
        clearFixtures()
    end)

    it('reads config.rsyslog', function()
        clearFixtures()
        local cfg = validFixtures()
        assert.is_table(cfg.rsyslog)
        clearFixtures()
    end)

    it('rejects request_budget_ms < source_budget_ms', function()
        clearFixtures()
        package.loaded['conf.config'] = {
            DEBUG = false, log_format = 'file',
            httptimeout_ms = 800, connect_timeout_ms = 300,
            source_budget_ms = 1000,
            request_budget_ms = 500,      -- 小于 source_budget_ms
            mysqltimeout_ms = 1000, pool_size = 300, pool_max_idle_time_ms = 0,
            dict_ttl_ms = 1000, max_body_bytes = 1024,
            dmp = {}, http_proxy = {}, rsyslog = {},
        }
        local cfg, err = config.load()
        assert.is_nil(cfg)
        assert.is_truthy(tostring(err):find('request_budget_ms', 1, true))
        clearFixtures()
    end)

    it('rejects an upstream host with a port suffix', function()
        -- 这类写法会让 proxy_pass $scheme://$host 指向白名单之外
        clearFixtures()
        local loaded = validFixtures()
        package.loaded['conf.system'].upstreams = {
            bad = { host = 'evil.com:6379/', port = 443, protocol = 'https' },
        }
        local cfg, err = config.load()
        assert.is_nil(cfg)
        assert.is_truthy(tostring(err):find('host', 1, true))
        clearFixtures()
    end)

    it('rejects a dmp entry with no matching vendor config', function()
        clearFixtures()
        validFixtures()
        package.loaded['conf.system'].vendors = {}
        local cfg, err = config.load()
        assert.is_nil(cfg)
        assert.is_truthy(tostring(err):find('vendors', 1, true))
        clearFixtures()
    end)

    it('rejects a cassandra table that is not a bare identifier', function()
        -- CQL 不支持占位符绑定表名，非标识符即等于拼接注入
        clearFixtures()
        validFixtures()
        package.loaded['conf.cassandra'].vendors = {
            example = { table = 'x; DROP TABLE users' },
        }
        package.loaded['conf.system'].vendors.example = {}
        local cfg, err = config.load()
        assert.is_nil(cfg)
        assert.is_truthy(tostring(err):find('table', 1, true))
        clearFixtures()
    end)

    it('rejects a redis cluster keyed on a non-existent source', function()
        -- 原版公开仓正是这种错：键写成 "redis" 而代码按 source 名查找
        clearFixtures()
        validFixtures()
        package.loaded['conf.cache'].redis_clusters = {
            redis = { { host = '10.0.0.1', port = 6379 } },
        }
        local cfg, err = config.load()
        assert.is_nil(cfg)
        assert.is_truthy(tostring(err):find('redis_clusters', 1, true))
        clearFixtures()
    end)

    it('reports all problems at once', function()
        clearFixtures()
        package.loaded['conf.config'] = {
            DEBUG = false, log_format = 'file',
            httptimeout_ms = -1,          -- 非法
            connect_timeout_ms = 0,       -- 非法
            source_budget_ms = 'abc',     -- 非法
            request_budget_ms = 1,
            mysqltimeout_ms = 1000,
            pool_size = 300, pool_max_idle_time_ms = 0,
            dict_ttl_ms = 1000, max_body_bytes = 1024,
            dmp = {}, http_proxy = {}, rsyslog = {},
        }
        local cfg, err = config.load()
        assert.is_nil(cfg)
        -- 一次性报出 3 项，而不是改一个报一个
        assert.is_truthy(tostring(err):find('3 项', 1, true))
        clearFixtures()
    end)
end)
