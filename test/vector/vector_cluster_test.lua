local t = require('luatest')
local server = require('luatest.server')

local g = t.group('crud_vector_cluster')

g.before_all(function(cg)
    t.skip_if(type(box.internal.vector_icu_version) ~= 'function',
              'Requires Tarantool with VECTOR support')
    cg.storages = {}
    cg.cfg = {bucket_count = 20, rebalancer_mode = 'off',
              sharding = {}}
    for i = 1, 2 do
        local rs = ('00000000-0000-0000-0000-%012d'):format(i)
        local s = server:new({alias = 'crud-vector-s' .. i,
                              box_cfg = {replicaset_uuid = rs}})
        cg.storages[i] = s
        s:start()
        local uri = s:exec(function(address)
            box.schema.user.create('storage', {password = 'storage'})
            box.schema.user.grant('storage', 'super')
            local luri = require('uri')
            local parsed = luri.parse(address)
            parsed.login, parsed.password = 'storage', 'storage'
            return luri.format(parsed, true)
        end, {s.net_box_uri})
        cg.cfg.sharding[rs] = {replicas = {
            [s:get_instance_uuid()] = {uri = uri, master = true},
        }}
    end
    for i, s in ipairs(cg.storages) do
        s:exec(function(cfg, first)
            local vshard = require('vshard')
            rawset(_G, 'vshard', vshard)
            vshard.storage.cfg(cfg, box.info.uuid)
            vshard.storage.bucket_force_create(first, 10)
            local space = box.schema.space.create('docs')
            space:format({{name = 'id', type = 'unsigned'},
                          {name = 'bucket_id', type = 'unsigned'},
                          {name = 'embedding', type = 'array'}})
            space:create_index('pk')
            space:create_index('bucket_id', {parts = {{2, 'unsigned'}},
                                             unique = false})
            space:create_index('vec', {type = 'vector', dimension = 2,
                                       distance = 'l2', unique = false,
                                       parts = {{3, 'array'}}})
            require('crud').init_storage({async = false})
            box.schema.user.create('reader')
            box.schema.user.grant('reader', 'read', 'space', 'docs')
        end, {cg.cfg, (i - 1) * 10 + 1})
    end
    cg.router = server:new({alias = 'crud-vector-router'})
    cg.router:start()
    cg.router:exec(function(cfg)
        rawset(_G, 'vshard', require('vshard'))
        require('vshard').router.cfg(cfg)
        require('crud').init_router()
        box.schema.user.create('reader')
    end, {cg.cfg})
    cg.router:exec(function()
        local crud = require('crud')
        for _, tuple in ipairs({{1, 1, {1, 0}}, {2, 11, {0, 1}},
                                 {3, 1, {1, 0}}}) do
            local result, err = crud.insert('docs', tuple,
                                            {bucket_id = tuple[2]})
            assert(result, tostring(err))
        end
    end)
end)

g.after_all(function(cg)
    if cg.router ~= nil then cg.router:drop() end
    for _, s in ipairs(cg.storages or {}) do s:drop() end
end)

g.test_scopes_custom_router_and_stats = function(cg)
    cg.router:exec(function(cfg)
        local crud = require('crud')
        crud.cfg({stats = true, stats_driver = 'local'})
        local rows, err = crud.vector_search('docs', 'vec', {1, 0},
                                              {k = 3, timeout = 5})
        t.assert_equals(err, nil)
        t.assert_equals(#rows, 3)
        t.assert_equals({rows[1].id[1], rows[2].id[1], rows[3].id[1]},
                        {1, 3, 2})
        t.assert_equals(rows[1].distance, 0)
        t.assert_equals(rows[1].vector, {1, 0})
        rows, err = crud.vector_search('docs', 'vec', {1, 0}, {
            k = 3, scope = {kind = 'bucket', bucket_id = 11}, timeout = 5,
        })
        t.assert_equals(err, nil)
        t.assert_equals(#rows, 1)
        t.assert_equals(rows[1].id, {2})
        local custom = require('vshard').router.new('vector-custom', cfg)
        rows, err = crud.vector_search('docs', 'vec', {1, 0}, {
            k = 3, scope = {kind = 'buckets', bucket_ids = {1, 11}},
            vshard_router = custom, timeout = 5,
        })
        t.assert_equals(err, nil)
        t.assert_equals(#rows, 3)
        rows, err = crud.vector_search('docs', 'vec', {1, 0}, {
            k = 3, scope = {kind = 'buckets', bucket_ids = {}},
        })
        t.assert_equals(err, nil)
        t.assert_equals(rows, {})
        rows, err = crud.vector_search('docs', 'vec', {1, 0}, {k = -1})
        t.assert_equals(rows, nil)
        t.assert_equals(err.class_name, 'VectorSearchError')
        t.assert_equals(crud.stats('docs').vector_search.ok.count, 4)
        t.assert_equals(crud.stats('docs').vector_search.error.count, 1)
        crud.cfg({stats = false})
    end, {cg.cfg})
end

g.test_caller_permissions = function(cg)
    local function search()
        return cg.router:exec(function()
            return box.session.su('reader', require('crud').vector_search,
                'docs', 'vec', {1, 0}, {k = 3, timeout = 5})
        end)
    end
    local rows, err = search()
    t.assert_equals(err, nil)
    t.assert_equals(#rows, 3)
    cg.storages[2]:exec(function()
        box.schema.user.revoke('reader', 'read', 'space', 'docs')
    end)
    rows, err = search()
    t.assert_equals(rows, nil)
    t.assert_str_contains(err.err, 'Space')
    cg.storages[2]:exec(function()
        box.schema.user.grant('reader', 'read', 'space', 'docs')
    end)
    rows, err = search()
    t.assert_equals(err, nil)
    t.assert_equals(#rows, 3)
end

g.test_migration_and_schema_mismatch = function(cg)
    local target = ('00000000-0000-0000-0000-%012d'):format(2)
    cg.storages[1]:exec(function(target)
        assert(require('vshard').storage.bucket_send(1, target,
                                                     {timeout = 5}))
        -- A leftover tuple must not become a duplicate search result.
        box.space.docs:replace{99, 1, {1, 0}}
    end, {target})
    cg.router:exec(function()
        local rows, err = require('crud').vector_search(
            'docs', 'vec', {1, 0}, {k = 3, timeout = 5})
        t.assert_equals(err, nil)
        t.assert_equals(#rows, 3)
        t.assert_equals(rows[1].id[1], 1)
        t.assert_equals(rows[2].id[1], 3)
    end)
    cg.storages[2]:exec(function()
        box.space.docs.index.vec:alter({distance = 'ip'})
    end)
    cg.router:exec(function()
        local rows, err = require('crud').vector_search(
            'docs', 'vec', {1, 0}, {k = 3, timeout = 5})
        t.assert_equals(rows, nil)
        t.assert_str_contains(tostring(err), 'Incompatible storage envelope')
    end)
    cg.storages[2]:exec(function()
        box.space.docs.index.vec:alter({distance = 'l2'})
    end)
end

g.test_timeout_and_unprotected_call = function(cg)
    cg.storages[1]:exec(function()
        local storage = require('crud.vector_search.storage')
        storage.saved_search = storage.search
        storage.search = function(...)
            require('fiber').sleep(0.2)
            return storage.saved_search(...)
        end
    end)
    cg.router:exec(function()
        local rows, err = require('crud').vector_search(
            'docs', 'vec', {1, 0}, {k = 3, timeout = 0.05})
        t.assert_equals(rows, nil)
        t.assert_str_contains(tostring(err), 'call failed')
    end)
    cg.storages[1]:exec(function()
        require('fiber').sleep(0.3)
        local storage = require('crud.vector_search.storage')
        storage.search = storage.saved_search
        storage.saved_search = nil
        local ok, err = pcall(rawget(_G, '_crud').vector_search,
            'reader', {space = 'docs', index = 'vec', query = {1, 0},
                       L = 1, scope = {kind = 'all'}}, 1)
        t.assert_equals(ok, false)
        t.assert_str_contains(tostring(err), 'Protected vshard call')
    end)
end
