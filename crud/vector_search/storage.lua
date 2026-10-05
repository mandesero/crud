local fiber = require('fiber')
local key_def = require('key_def')
local msgpack = require('msgpack')
local wire = require('crud.vector_search.wire')

local M = {}

local function fail(kind, reason)
    error(box.error.new({type = kind, reason = reason}), 0)
end

local function array()
    return setmetatable({}, {__serialize = 'seq'})
end

local function finite(value)
    return type(value) == 'number' and value == value and
           value ~= math.huge and value ~= -math.huge
end

local function positive_integer(value)
    return (type(value) == 'number' or type(value) == 'cdata') and
           value > 0 and value % 1 == 0
end

local function nonnegative_integer(value)
    return (type(value) == 'number' or type(value) == 'cdata') and
           value >= 0 and value % 1 == 0
end

local function check_fields(value, allowed, kind)
    if type(value) ~= 'table' then
        fail(kind, 'Expected a table')
    end
    for key in pairs(value) do
        if not allowed[key] then
            fail(kind, 'Unknown field: ' .. tostring(key))
        end
    end
end

local function array_length(value, max_count)
    if type(value) ~= 'table' then
        return nil
    end
    local count = 0
    for key in pairs(value) do
        if not nonnegative_integer(key) or key == 0 or
           key > max_count then
            return nil
        end
        count = count + 1
    end
    for i = 1, count do
        if rawget(value, i) == nil then
            return nil
        end
    end
    return count
end

local request_fields = {
    space = true, index = true, query = true, L = true, scope = true,
    algorithm_opts = true,
}

local scope_fields = {
    kind = true, bucket_id = true, bucket_ids = true,
}

local algorithm_fields = {ef_search = true}

local function metadata(def)
    return {
        version = 1,
        dimension = def.dimension,
        distance = def.distance,
        scalar = 'float32',
        numeric_contract = 'f32_f64_v1',
        pk = def.pk_metadata,
        schema = def.schema,
    }
end

local function envelope(def)
    local result = metadata(def)
    result.covered_bucket_ids = array()
    result.records = array()
    return result
end

local function remaining(deadline)
    local value = deadline - fiber.clock()
    if value <= 0 then
        fail('VECTOR_TIMEOUT', 'Storage search deadline exceeded')
    end
    return value
end

local function requested_buckets(request, context, max_buckets)
    local scope = request.scope
    check_fields(scope, scope_fields, 'VECTOR_INVALID')
    if scope.kind == 'all' then
        if scope.bucket_id ~= nil or scope.bucket_ids ~= nil then
            fail('VECTOR_INVALID', 'Conflicting scope fields')
        end
        local protected = context:bucket_ids(max_buckets)
        local result = array()
        for i, id in ipairs(protected) do
            result[i] = id
        end
        return result
    end
    local wanted = array()
    if scope.kind == 'bucket' then
        if scope.bucket_ids ~= nil or
           not positive_integer(scope.bucket_id) then
            fail('VECTOR_INVALID', 'Invalid bucket scope')
        end
        wanted[1] = scope.bucket_id
    elseif scope.kind == 'buckets' then
        if scope.bucket_id ~= nil or
           array_length(scope.bucket_ids, max_buckets) == nil then
            fail('VECTOR_INVALID', 'Invalid bucket set')
        end
        for i, id in ipairs(scope.bucket_ids) do
            if not positive_integer(id) then
                fail('VECTOR_INVALID', 'Invalid bucket identifier')
            end
            wanted[i] = id
        end
    else
        fail('VECTOR_INVALID', 'Unknown bucket scope')
    end
    local result = array()
    for _, id in ipairs(wanted) do
        if context:contains(id) then
            result[#result + 1] = id
        end
    end
    if context.mode == 'bucket' and scope.kind == 'bucket' and
       #result == 0 then
        fail('VECTOR_COVERAGE', 'Bucket does not match protected call')
    end
    return result
end

local function sort_records(records, def)
    table.sort(records, function(a, b)
        if a.distance ~= b.distance then
            return a.distance < b.distance
        end
        if a.bucket_id ~= b.bucket_id then
            return def.bucket_key_def:compare_keys(
                {a.bucket_id}, {b.bucket_id}) < 0
        end
        return def.pk_key_def:compare_keys(a.id, b.id) < 0
    end)
end

local function project(rows, def, deadline)
    local records = array()
    for i, row in ipairs(rows) do
        if i % 64 == 0 then
            remaining(deadline)
        end
        local tuple = row.tuple
        local id = array()
        for j, part in ipairs(def.pk_parts) do
            id[j] = tuple[part.fieldno]
        end
        records[i] = {
            id = id,
            bucket_id = tuple[def.bucket_fieldno],
            vector = tuple[def.vector_fieldno],
            distance = row.distance,
        }
    end
    return records
end

local function definition(space_name, index_name)
    if type(space_name) ~= 'string' or space_name == '' or
       type(index_name) ~= 'string' or index_name == '' then
        fail('VECTOR_INVALID', 'Space and index names are required')
    end
    local opts = {space = space_name, index = index_name,
                  bucket_field = 'bucket_id', bucket_index = 'bucket_id'}
    local space = box.space[opts.space]
    if space == nil then
        fail('VECTOR_INVALID', 'Space is unavailable')
    end
    local index = space.index[opts.index]
    local pk = space.index[0]
    local bucket_index = space.index[opts.bucket_index]
    if index == nil or index.type ~= 'VECTOR' or
       pk == nil or pk.id ~= 0 or bucket_index == nil then
        fail('VECTOR_INVALID', 'Invalid index configuration')
    end
    local bucket_fieldno
    for i, field in ipairs(space:format()) do
        if field.name == opts.bucket_field then
            if field.type ~= 'unsigned' then
                fail('VECTOR_INVALID', 'Bucket field must be unsigned')
            end
            bucket_fieldno = i
            break
        end
    end
    if bucket_fieldno == nil or
       bucket_index.parts[1].fieldno ~= bucket_fieldno then
        fail('VECTOR_INVALID', 'Missing bucket index')
    end
    local pk_parts = array()
    for i, part in ipairs(pk.parts) do
        if part.is_nullable or part.path ~= nil then
            fail('VECTOR_UNSUPPORTED', 'Unsupported primary key part')
        end
        pk_parts[i] = part
    end
    local ok, storage = pcall(require, 'vshard.storage')
    if not ok or type(storage.call_context) ~= 'function' then
        fail('VECTOR_UNSUPPORTED', 'Patched vshard storage is required')
    end
    local stat = index:stat().config
    local pk_metadata = wire.pk_metadata(pk_parts)
    return {
        space = opts.space,
        index = opts.index,
        bucket_fieldno = bucket_fieldno,
        bucket_field = opts.bucket_field,
        vector_fieldno = index.parts[1].fieldno,
        dimension = stat.dimension,
        distance = stat.distance,
        pk_parts = pk_parts,
        pk_metadata = pk_metadata,
        schema = wire.schema(space, index, bucket_fieldno),
        pk_key_def = wire.key_def(pk_metadata),
        bucket_key_def = key_def.new({{
            fieldno = 1, type = 'unsigned',
        }}),
        max_buckets = 65536,
        max_limit = 1024,
        max_response_bytes = 32 * 1024 * 1024,
    }
end

function M.search(request, remaining_timeout)
    check_fields(request, request_fields, 'VECTOR_INVALID')
    if not finite(remaining_timeout) or remaining_timeout <= 0 then
        fail('VECTOR_TIMEOUT', 'No remaining storage budget')
    end
    local deadline = fiber.clock() + math.min(remaining_timeout, 30)
    local def = definition(request.space, request.index)
    if not nonnegative_integer(request.L) or request.L > def.max_limit or
       array_length(request.query, def.dimension) ~= def.dimension then
        fail('VECTOR_INVALID', 'Invalid storage query or limit')
    end
    local algorithm_opts = request.algorithm_opts or {}
    check_fields(algorithm_opts, algorithm_fields, 'VECTOR_INVALID')
    local context = require('vshard.storage').call_context()
    if context == nil or type(context.bucket_ids) ~= 'function' then
        fail('VECTOR_COVERAGE', 'Protected vshard call is required')
    end
    local index = box.space[def.space].index[def.index]
    -- Ownership is system metadata. Keep the user ACL for the data select.
    local buckets = box.session.su('admin', requested_buckets,
                                   request, context, def.max_buckets)
    local select_opts = {
        iterator = 'neighbor', limit = #buckets == 0 and 0 or request.L,
        with_distance = true, timeout = remaining(deadline),
        filter = {field = def.bucket_field, values = buckets},
    }
    if algorithm_opts.ef_search ~= nil then
        select_opts.opts = algorithm_opts
    end
    local rows = index:select({request.query}, select_opts)
    local result = envelope(def)
    result.covered_bucket_ids = buckets
    result.records = project(rows, def, deadline)
    sort_records(result.records, def)
    remaining(deadline)
    if #msgpack.encode(result) > def.max_response_bytes then
        fail('VECTOR_WORK_LIMIT', 'Storage response size limit exceeded')
    end
    return result
end

-- VECTOR search can yield; CRUD's non-yielding DML dispatcher cannot be used.
local function search_as_user(user, request, budget)
    return box.session.su(user, M.search, request, budget)
end

M.storage_api = {vector_search = search_as_user}

return M
