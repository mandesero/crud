local errors = require('errors')
local utils = require('crud.common.utils')

local VectorSearchError = errors.new_class('VectorSearchError')
local M = {storage_api = {}}

-- Load VECTOR dependencies only when used, including on older Tarantool.
function M.storage_api.vector_search(...)
    return require('crud.vector_search.storage').storage_api.vector_search(...)
end

--- Search a VECTOR index across protected vshard masters.
-- Returns distance-ordered records, or nil and an error.
function M.call(space_name, index_name, query, opts)
    if type(space_name) ~= 'string' or space_name == '' or
       type(index_name) ~= 'string' or index_name == '' or
       (opts ~= nil and type(opts) ~= 'table') then
        return nil, VectorSearchError:new('Invalid space, index or options')
    end
    opts = opts or {}
    if type(box.internal.vector_icu_version) ~= 'function' then
        return nil, VectorSearchError:new(
            'Tarantool with VECTOR support is required')
    end
    local ok, instance, err = pcall(utils.get_vshard_router_instance,
                                  opts.vshard_router)
    if not ok then
        return nil, VectorSearchError:new('%s', tostring(instance))
    end
    if instance == nil then
        return nil, err
    end
    local result
    ok, result = pcall(function()
        return require('crud.vector_search.router').search(
            instance, space_name, index_name, query, opts)
    end)
    if not ok then
        return nil, VectorSearchError:new('%s', tostring(result))
    end
    return result
end

return M
