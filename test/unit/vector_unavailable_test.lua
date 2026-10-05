local t = require('luatest')
local server = require('luatest.server')

local g = t.group('vector_unavailable')

g.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.test_lazy_dependencies_and_unsupported_error = function(cg)
    cg.server:exec(function()
        local crud = require('crud')
        t.assert_equals(package.loaded['crud.vector_search.router'], nil)
        t.assert_equals(package.loaded['crud.vector_search.storage'], nil)
        local saved = box.internal.vector_icu_version
        box.internal.vector_icu_version = nil
        local rows, err = crud.vector_search('docs', 'vec', {1, 0}, {k = 1})
        box.internal.vector_icu_version = saved
        t.assert_equals(rows, nil)
        t.assert_equals(err.class_name, 'VectorSearchError')
        t.assert_str_contains(tostring(err), 'VECTOR support is required')
        t.assert_equals(package.loaded['crud.vector_search.router'], nil)
        rows, err = crud.vector_search({}, 'vec', {1, 0}, {k = 1})
        t.assert_equals(rows, nil)
        t.assert_str_contains(tostring(err), 'Invalid space')
    end)
end
