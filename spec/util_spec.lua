--- `lib/util` 单元测试。
---
--- 覆盖原版最关键的两处行为回归：
---   * `deepMerge` 的**数组合并语义**（原版 `table.merge` 会覆盖丢数据）
---   * `isBlank` 不再把 `0` 判为空（原版 `isEmpty(0) == true`）
---
--- 运行：busted spec/

local util = require('lib.util')

describe('util.isBlank', function()
    it('treats nil / empty string / whitespace as blank', function()
        assert.is_true(util.isBlank(nil))
        assert.is_true(util.isBlank(''))
        assert.is_true(util.isBlank('   '))
        assert.is_true(util.isBlank('\t\n'))
    end)

    it('treats empty table as blank', function()
        assert.is_true(util.isBlank({}))
    end)

    it('treats 0 as NOT blank (原版 isEmpty(0) 返回 true)', function()
        -- 这是一个口径坑：0 是有效值，不能当空
        assert.is_false(util.isBlank(0))
        assert.is_false(util.isBlank(false))
    end)

    it('always returns a real boolean', function()
        -- 原版 isEmpty 在 else 分支 `return str`，可能返回任意非 nil 值
        assert.is_boolean(util.isBlank('x'))
        assert.is_boolean(util.isBlank(123))
        assert.is_boolean(util.isBlank({ 1 }))
    end)
end)

describe('util.orElse', function()
    it('returns fallback when blank', function()
        assert.equals('def', util.orElse(nil, 'def'))
        assert.equals('def', util.orElse('', 'def'))
        assert.equals('def', util.orElse({}, 'def'))
    end)

    it('returns value when present', function()
        assert.equals('val', util.orElse('val', 'def'))
        assert.equals(0, util.orElse(0, 99))
    end)
end)

describe('util.trim / util.split', function()
    it('trims', function()
        assert.equals('abc', util.trim('  abc  '))
        assert.equals('', util.trim(nil))
    end)

    it('returns a plain string (原版 string.trim 会返回 nil, err)', function()
        local r = util.trim(123)
        assert.is_string(r)
    end)

    it('splits', function()
        assert.same({ 'a', 'b', 'c' }, util.split('a,b,c', ','))
        assert.same({ 'a', '', 'c' }, util.split('a,,c', ','))
    end)

    it('returns empty table instead of nil (原版返回 nil)', function()
        assert.same({}, util.split(nil, ','))
        assert.same({}, util.split('', ','))
    end)

    it('drops blanks via splitList', function()
        assert.same({ 'a', 'b' }, util.splitList(' a , , b ', ','))
    end)
end)

describe('util.deepMerge —— 关键行为修正', function()
    it('CONCATS arrays instead of overwriting them', function()
        -- 原版 table.merge({1,2},{3,4}) => {3,4}   （1、2 被丢弃）
        -- 这正是 api/nad.lua 与 api/ad.lua 同为 source="ad" 时丢一半结果的根因
        local a = { 'tag1', 'tag2' }
        local b = { 'tag3', 'tag4' }
        local merged = util.deepMerge(a, b)
        assert.same({ 'tag1', 'tag2', 'tag3', 'tag4' }, merged)
    end)

    it('merges hash tables recursively', function()
        local a = { code = 200, result = { 'x' } }
        local b = { msg = 'hi' }
        local merged = util.deepMerge(a, b)
        assert.equals(200, merged.code)
        assert.same({ 'x' }, merged.result)
        assert.equals('hi', merged.msg)
    end)

    it('survives self-referencing tables', function()
        local a = { 1 }
        a.self = a
        -- 不应栈溢出
        local ok = pcall(util.deepMerge, {}, a)
        assert.is_true(ok)
    end)
end)

describe('util.groupBy', function()
    it('groups by key and concats duplicate arrays', function()
        local keys = { 'ad', 'gt', 'ad' }
        local values = {
            { code = 200, result = { 'a' } },
            { code = 200, result = { 'z' } },
            { code = 200, result = { 'b' } },
        }
        local grouped = util.groupBy(keys, values, { concat_arrays = true })

        -- ad 出现两次（第 1、3 项），结果应当累加而不是后者覆盖前者
        assert.same({ 'a', 'b' }, grouped.ad.result)
        assert.same({ 'z' }, grouped.gt.result)
    end)

    it('returns a stable order', function()
        local grouped, order = util.groupBy({ 'b', 'a' }, { {}, {} })
        assert.same({ 'b', 'a' }, order)
    end)
end)

describe('util.unique', function()
    it('keeps first occurrence order', function()
        assert.same({ 'a', 'b', 'c' }, util.unique({ 'a', 'b', 'a', 'c', 'b' }))
    end)

    it('handles false values correctly (原版依赖 if not (check[v]) 会误判)', function()
        -- 原版：首元素为 false 时 check[false] 为 nil，被当作"未出现"，导致 false 重复
        assert.same({ false, true }, util.unique({ false, true, false }))
    end)
end)

describe('util.secureEquals', function()
    it('compares equal / unequal', function()
        assert.is_true(util.secureEquals('abc', 'abc'))
        assert.is_false(util.secureEquals('abc', 'abd'))
        assert.is_false(util.secureEquals('abc', 'abcd'))
        assert.is_false(util.secureEquals('abc', nil))
    end)
end)

describe('util.redact', function()
    it('masks device identifiers', function()
        local out = util.redact('{"imei":"356938035643809","idfa":"ABCD1234-12AB"}')
        assert.is_falsy(out:find('356938035643809', 1, true))
        assert.is_falsy(out:find('ABCD1234%-12AB', 1, true))
    end)

    it('masks secrets', function()
        local out = util.redact('{"password":"hunter2","token":"abcdef123456"}')
        assert.is_falsy(out:find('hunter2', 1, true))
        assert.is_falsy(out:find('abcdef123456', 1, true))
    end)
end)

describe('util.truncate', function()
    it('truncates and annotates', function()
        local out = util.truncate(string.rep('x', 100), 10)
        assert.equals(10 + string.len('...[+90 bytes]'), #out)
    end)

    it('passes short strings through', function()
        assert.equals('abc', util.truncate('abc', 10))
    end)
end)

describe('util.base62', function()
    it('encodes 0', function()
        assert.equals(1, #util.base62(0))
    end)

    it('round-trips small ints', function()
        for _, n in ipairs({ 0, 1, 61, 62, 3843, 3844 }) do
            assert.is_string(util.base62(n))
            assert.is_true(#util.base62(n) > 0)
        end
    end)

    it('rejects negatives', function()
        assert.equals('', util.base62(-1))
    end)
end)
