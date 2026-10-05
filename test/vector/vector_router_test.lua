local server = require('luatest.server')
local t = require('luatest')
local path = require('test.path')

local g = t.group('crud_vector_router')

g.before_all(function(cg)
    t.skip_if(type(box.internal.vector_icu_version) ~= 'function',
              'Requires Tarantool with VECTOR support')
    cg.server = server:new({
        env = {
            LUA_PATH = path.LUA_PATH .. ';' .. package.path,
            LUA_CPATH = package.cpath,
        },
    })
    cg.server:start()
end)

g.after_all(function(cg)
    if cg.server ~= nil then cg.server:drop() end
end)

g.test_option_validation = function(cg)
    cg.server:exec(function()
        local instance = {bucket_count = function() return 3 end}
        local router = require('crud.vector_search.router')
        local cases = {
            {k = 1, L = false}, {k = 1, L = 0},
            {k = 1, timeout = false}, {k = 1, timeout = math.huge},
            {k = 1, algorithm_opts = false},
            {k = 1, algorithm_opts = {ef_search = 8193}},
            {k = 1, max_participants = false},
            {k = 1, max_pk_bytes = 0}, {k = 1, max_response_bytes = -1},
            {k = 1, scope = false},
            {k = 1, scope = {kind = 'buckets', bucket_ids = {1, 1}}},
            {k = 1, scope = {kind = 'bucket', bucket_id = 4}},
            {k = 1, unknown = true},
        }
        for _, opts in ipairs(cases) do
            local ok, err = pcall(router.search, instance, 'docs', 'vec',
                                  {1, 0}, opts)
            t.assert_equals(ok, false)
            t.assert_equals(err.type, 'VECTOR_INVALID')
        end
        for _, query in ipairs({{}, {1, math.huge}, {[1] = 1, [3] = 0}}) do
            local ok, err = pcall(router.search, instance, 'docs', 'vec',
                                  query, {k = 1})
            t.assert_equals(ok, false)
            t.assert_equals(err.type, 'VECTOR_INVALID')
        end
        t.assert_equals(router.search(instance, 'docs', 'vec', {1, 0},
                                     {k = 0}), {})
    end)
end

g.test_merge_and_protocol = function(cg)
    cg.server:exec(function()
        local state = {map = nil, single = nil, calls = 0}
        local instance
        instance = {
            bucket_count = function() return 3 end,
            info = function()
                return {replicasets = {one = {}, two = {}}}
            end,
            callrw = function(self, bucket, name, args)
                state.calls = state.calls + 1
                t.assert_equals(bucket, 1)
                t.assert_equals(self, instance)
                t.assert_equals(name, '_crud.vector_search')
                t.assert_equals(args[1], box.session.effective_user())
                t.assert(args[3] > 0)
                return state.single
            end,
            map_callrw = function(self, name, args, opts)
                state.calls = state.calls + 1
                t.assert_equals(self, instance)
                t.assert_equals(name, '_crud.vector_search')
                t.assert_equals(args[1], box.session.effective_user())
                t.assert_equals(opts.remaining_timeout_arg, 3)
                t.assert(args[3] > 0)
                return state.map
            end,
        }
        local wire = require('crud.vector_search.wire')
        local router = require('crud.vector_search.router')
        local parts = {{fieldno = 1, type = 'unsigned'},
                       {fieldno = 2, type = 'string',
                        collation = 'unicode_ci'}}
        local pk = wire.pk_metadata(parts)
        t.assert_equals(pk.parts[2].collation.name, 'unicode_ci')
        t.assert_equals(#pk.parts[2].collation.fingerprint, 64)
        t.assert_equals(pk.parts[2].collation.icu_version,
                        box.internal.vector_icu_version())
        local function record(bucket, id1, id2, distance)
            return {id = {id1, id2}, bucket_id = bucket,
                    vector = {1, 0}, distance = distance}
        end
        local function env(buckets, records)
            return {version = 1, dimension = 2, distance = 'l2',
                    scalar = 'float32', numeric_contract = 'f32_f64_v1',
                    pk = pk, schema = string.rep('a', 64),
                    covered_bucket_ids = buckets,
                    records = records}
        end
        local ffi = require('ffi')
        local big = ffi.new('uint64_t', 9007199254740992) +
                    ffi.new('uint64_t', 1)
        local first, second
        local function reset()
            first = env({1, 2}, {
                record(1, big, 'A', 0.1),
                record(2, big, 'b', 0.2),
            })
            second = env({3}, {
                record(3, big, 'C', 0.1),
            })
            state.map = {one = {first}, two = {second}}
            state.single = env({1}, {first.records[1]})
        end
        local function fails(fragment, fn)
            local ok, err = pcall(fn)
            t.assert_equals(ok, false)
            t.assert_str_contains(tostring(err), fragment)
        end
        local opts = {k = 2, L = 3}
        reset()
        local result = router.search(instance, 'docs', 'vec', {1, 0}, opts)
        t.assert_equals(#result, 2)
        t.assert_equals(result[1].bucket_id, 1)
        t.assert_equals(result[2].bucket_id, 3)
        t.assert_equals(result[1].id[1], big)
        t.assert_equals(result[1].vector, {1, 0})
        first = env({1, 2}, {
            record(1, big + 1, 'z', 0.1),
            record(2, big, 'a', 0.1),
            record(2, big, 'b', 0.2),
        })
        second = env({3}, {
            record(3, big, 'C', 0.05),
            record(3, big + 1, 'D', 0.1),
            record(3, big + 2, 'E', 0.3),
        })
        state.map = {one = {first}, two = {second}}
        opts.k = 4
        opts.L = 8
        result = router.search(instance, 'docs', 'vec', {1, 0}, opts)
        local all = {}
        for _, list in ipairs({first.records, second.records}) do
            for _, item in ipairs(list) do
                all[#all + 1] = item
            end
        end
        local pk_def = wire.key_def(pk)
        table.sort(all, function(a, b)
            if a.distance ~= b.distance then
                return a.distance < b.distance
            end
            if a.bucket_id ~= b.bucket_id then
                return a.bucket_id < b.bucket_id
            end
            return pk_def:compare_keys(a.id, b.id) < 0
        end)
        t.assert_equals(result, {all[1], all[2], all[3], all[4]})
        reset()
        opts.k = 2
        opts.L = 3
        opts.scope = {kind = 'bucket', bucket_id = 1}
        result = router.search(instance, 'docs', 'vec', {1, 0}, opts)
        t.assert_equals(result[1].bucket_id, 1)
        opts.scope = {kind = 'buckets', bucket_ids = {}}
        local before = state.calls
        result = router.search(instance, 'docs', 'vec', {1, 0}, opts)
        t.assert_equals(#result, 0)
        t.assert_equals(state.calls, before)
        opts.scope = {kind = 'buckets', bucket_ids = {1, 3}}
        fails('Unexpected bucket coverage', function()
            router.search(instance, 'docs', 'vec', {1, 0}, opts)
        end)
        opts.scope = {kind = 'all'}
        first.records[2].distance = 0.05
        fails('Unsorted storage records', function()
            router.search(instance, 'docs', 'vec', {1, 0}, opts)
        end)
        first.records[2].distance = 0.2
        first.records[1].distance = 0 / 0
        fails('Invalid storage record', function()
            router.search(instance, 'docs', 'vec', {1, 0}, opts)
        end)
        first.records[1].distance = 0.1
        second.pk = table.deepcopy(pk)
        second.pk.parts[2].collation.fingerprint = 'wrong'
        fails('Incompatible storage envelope', function()
            router.search(instance, 'docs', 'vec', {1, 0}, opts)
        end)
        second.pk = pk
        second.covered_bucket_ids = {2, 3}
        fails('Duplicate or invalid bucket coverage', function()
            router.search(instance, 'docs', 'vec', {1, 0}, opts)
        end)
        second.covered_bucket_ids = {3}
        second.records[1].bucket_id = 1
        second.covered_bucket_ids = {1, 3}
        fails('Duplicate or invalid bucket coverage', function()
            router.search(instance, 'docs', 'vec', {1, 0}, opts)
        end)
        reset()
        first.records[2] = record(1, big, 'A', 0.1)
        fails('Duplicate distributed identity', function()
            router.search(instance, 'docs', 'vec', {1, 0}, opts)
        end)
        reset()
        state.map.two = nil
        fails('Missing map participant', function()
            router.search(instance, 'docs', 'vec', {1, 0}, opts)
        end)
        reset()
        state.map = nil
        fails('Map call failed', function()
            router.search(instance, 'docs', 'vec', {1, 0}, opts)
        end)
        reset()
        opts.timeout = 0.001
        local original_map = instance.map_callrw
        instance.map_callrw = function()
            require('fiber').sleep(0.01)
            return state.map
        end
        fails('Router search deadline', function()
            router.search(instance, 'docs', 'vec', {1, 0}, opts)
        end)
        instance.map_callrw = original_map
        opts.timeout = nil
        opts.max_response_bytes = 100
        before = state.calls
        fails('Estimated response exceeds router limit', function()
            router.search(instance, 'docs', 'vec', {1, 0}, opts)
        end)
        t.assert_equals(state.calls, before)
    end)
end

g.test_wire_scalar_types = function(cg)
    cg.server:exec(function()
        local ffi = require('ffi')
        local msgpack = require('msgpack')
        local wire = require('crud.vector_search.wire')
        local big = ffi.new('uint64_t', 9007199254740992) +
                    ffi.new('uint64_t', 1)
        local uuid = require('uuid')
        local decimal = require('decimal')
        local datetime = require('datetime')
        local varbinary = require('varbinary')
        local cases = {
            {'unsigned', big, big + 1},
            {'integer', -2, -1},
            {'int8', -2, -1},
            {'uint8', 1, 2},
            {'int64', -2, -1},
            {'uint64', big, big + 1},
            {'number', 1.5, 2.5},
            {'double', 1.5, 2.5},
            {'float64', ffi.new('double', 1.5),
                        ffi.new('double', 2.5)},
            {'string', 'A', 'b'},
            {'varbinary', varbinary.new('a'), varbinary.new('b')},
            {'boolean', false, true},
            {'scalar', 'a', 'b'},
            {'decimal', decimal.new('1.25'), decimal.new('2.25')},
            {'decimal32', decimal.new('1.25'),
                          decimal.new('2.25'), 2},
            {'uuid', uuid.fromstr('00000000-0000-0000-0000-000000000001'),
                     uuid.fromstr('00000000-0000-0000-0000-000000000002')},
            {'datetime', datetime.new{year = 2020},
                         datetime.new{year = 2021}},
        }
        for _, case in ipairs(cases) do
            local pk = wire.pk_metadata({{type = case[1], scale = case[4]}})
            local def = wire.key_def(pk)
            local decoded = msgpack.decode(msgpack.encode({case[2],
                                                            case[3]}))
            t.assert(def:compare_keys({decoded[1]}, {decoded[2]}) < 0,
                     case[1])
        end
        local ok, err = pcall(wire.key_def,
                              wire.pk_metadata({{type = 'float32'}}))
        t.assert_not(ok)
        t.assert_str_contains(tostring(err), 'no wire comparator')
    end)
end
