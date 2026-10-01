--- `lib/envelope` 单元测试。

local env = require('lib.envelope')

describe('envelope.hit', function()
    it('returns HIT with tags', function()
        local e = env.hit({ '1001', '1002' }, 12)
        assert.equals(200, e.code)
        assert.equals('', e.msg)
        assert.same({ '1001', '1002' }, e.result)
        assert.equals(12, e.elapsed)
    end)

    it('degrades to NO_MATCH on empty result', function()
        local e = env.hit({}, 5)
        assert.equals(204, e.code)
        assert.same({}, e.result)
    end)

    it('always returns an array result', function()
        -- 原版 td.lua:94 把裸 JSON 片段直接嵌入字符串，导致 result 有时是数组有时是字符串
        local e = env.hit({ 'x' }, 1)
        assert.equals('table', type(e.result))
    end)

    it('tolerates nil / non-array input', function()
        assert.equals(204, env.hit(nil, 0).code)
        assert.equals(204, env.hit('not a table', 0).code)
    end)
end)

describe('envelope.fail', function()
    it('always returns an empty result', function()
        local e = env.fail(env.CODES.UPSTREAM_TIMEOUT, 'took too long', 900)
        assert.equals(504, e.code)
        assert.same({}, e.result)
        assert.is_truthy(e.msg:find('took too long', 1, true))
    end)

    it('has a message for every declared code', function()
        for name, code in pairs(env.CODES) do
            assert.is_string(env.MESSAGES[code], 'missing message for ' .. name)
        end
    end)
end)

describe('envelope.fromLegacy', function()
    it('maps a legacy { code, result } table', function()
        local e = env.fromLegacy({ code = 200, result = { 'a' } }, 3)
        assert.equals(200, e.code)
        assert.same({ 'a' }, e.result)
    end)

    it('turns unknown codes into INTERNAL', function()
        local e = env.fromLegacy({ code = 999, result = {} }, 1)
        assert.equals(500, e.code)
    end)

    it('handles a non-table return', function()
        assert.equals(500, env.fromLegacy('oops', 1).code)
        assert.equals(500, env.fromLegacy(nil, 1).code)
    end)
end)

describe('envelope.flatten', function()
    it('returns only hits', function()
        local grouped = {
            ad = env.hit({ '1' }, 1),
            gt = env.noMatch(2),
            td = env.fail(env.CODES.UPSTREAM_TIMEOUT, 'x', 900),
        }
        local hits, codes = env.flatten(grouped)
        assert.same({ ad = { '1' } }, hits)
        assert.equals(200, codes.ad)
        assert.equals(204, codes.gt)
        assert.equals(504, codes.td)
    end)
end)
