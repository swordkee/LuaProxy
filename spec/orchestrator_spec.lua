--- `lib/orchestrator` 的纯逻辑部分测试。
---
--- 注意：`run()` 依赖 `ngx.thread`，无法在 busted 中直接跑；
--- 这里只覆盖 `merge` / `toResponse` / `buildPlans` 的可测行为，
--- 其余逻辑的验证依赖集成测试（见 README「验证」一节）。

local orchestrator = require('lib.orchestrator')
local env = require('lib.envelope')

describe('orchestrator.merge', function()
    it('keeps distinct sources separate', function()
        local grouped = orchestrator.merge({
            { source = 'ad', envelope = env.hit({ '1' }, 1) },
            { source = 'gt', envelope = env.hit({ '2' }, 2) },
        })
        assert.same({ '1' }, grouped.ad.result)
        assert.same({ '2' }, grouped.gt.result)
    end)

    it('CONCATS results when the same source appears twice', function()
        -- 原版这里走 table.merge，结果被后者覆盖。
        -- api/nad.lua 与 api/ad.lua 同为 source="ad" 时即触发该问题。
        local grouped = orchestrator.merge({
            { source = 'ad', envelope = env.hit({ 'a1' }, 1) },
            { source = 'ad', envelope = env.hit({ 'a2' }, 2) },
        })
        assert.same({ 'a1', 'a2' }, grouped.ad.result)
    end)

    it('skips malformed parts', function()
        local grouped = orchestrator.merge({
            { source = 'ad', envelope = env.hit({ 'x' }, 1) },
            nil,
            { envelope = env.hit({ 'y' }, 1) },
        })
        assert.equals(1, #grouped.ad.result)
    end)
end)

describe('orchestrator.toResponse', function()
    it('reports HIT when any source hits', function()
        local grouped = {
            ad = env.hit({ '1' }, 5),
            gt = env.noMatch(3),
        }
        local out = orchestrator.toResponse(grouped, { elapsed = 9 })
        assert.equals(200, out.code)
        assert.same({ ad = { '1' } }, out.sources)
        assert.equals(9, out.elapsed)
    end)

    it('reports NO_MATCH when nothing hits and nothing fails', function()
        local out = orchestrator.toResponse({ ad = env.noMatch(1) }, { elapsed = 2 })
        assert.equals(204, out.code)
    end)

    it('reports UPSTREAM_UNAVAILABLE on hard failure', function()
        local out = orchestrator.toResponse({
            ad = env.fail(env.CODES.UPSTREAM_TIMEOUT, 'slow', 900),
        }, { elapsed = 900 })
        assert.equals(503, out.code)
    end)

    it('prefers HIT over failure', function()
        local out = orchestrator.toResponse({
            ad = env.hit({ '1' }, 1),
            gt = env.fail(504, 'slow', 900),
        }, { elapsed = 900 })
        assert.equals(200, out.code)
    end)

    it('excludes non-hit sources from .sources', function()
        local out = orchestrator.toResponse({
            ad = env.hit({ '1' }, 1),
            gt = env.noMatch(1),
        }, { elapsed = 1 })
        assert.is_nil(out.sources.gt)
    end)

    it('emits diagnostics for dropped sources', function()
        local out = orchestrator.toResponse({
            ad = env.hit({ '1' }, 1),
        }, {
            elapsed = 1,
            unknown = { 'typo' },
            timed_out = { 'gt' },
            rejected = { { index = 2, err = 'upstream "x" is not registered' } },
        })
        assert.is_truthy(out.diag:find('unknown=typo', 1, true))
        assert.is_truthy(out.diag:find('timeout=gt', 1, true))
        assert.is_truthy(out.diag:find('rejected=', 1, true))
    end)

    it('omits diag when everything is clean', function()
        local out = orchestrator.toResponse({ ad = env.hit({ '1' }, 1) }, { elapsed = 1 })
        assert.is_nil(out.diag)
    end)
end)
