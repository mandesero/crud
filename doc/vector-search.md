# Distributed VECTOR search

This experimental API requires the VECTOR-enabled Tarantool fork and the
vshard fork that provides protected call contexts and remaining map budgets:

* Tarantool: `mandesero/tarantool`, branch `codex/vector-index-rfc-v3`.
* vshard: `mandesero/vshard`, commit
  `674cda708d957cc145aa4f0622804bb5c2f8007a`.

The ordinary CRUD router/storage roles initialize vector search. No separate
vector storage role or logical collection registration is required.
Create a memtx space with a primary key, an unsigned `bucket_id` field, an
index named `bucket_id` whose first part is that field, and a VECTOR index.
The primary key must have at most 32 non-nullable parts without JSON paths.
The `float32` primary key type cannot be compared after MsgPack transport.

```lua
-- On each storage, after vshard has been configured:
local s = box.schema.space.create('documents')
s:format({{name = 'id', type = 'unsigned'},
          {name = 'bucket_id', type = 'unsigned'},
          {name = 'embedding', type = 'array'}})
s:create_index('primary')
s:create_index('bucket_id', {unique = false, parts = {{2, 'unsigned'}}})
s:create_index('embedding', {
    type = 'vector', dimension = 3, distance = 'cosine',
    unique = false, parts = {{3, 'array'}},
})
require('crud').init_storage()

-- On the router:
local crud = require('crud')
crud.init_router()
local records, err = crud.vector_search('documents', 'embedding',
    {0.1, 0.2, 0.3}, {k = 10, L = 50, timeout = 1})
assert(records, tostring(err))
```

`crud.vector_search(space_name, index_name, query, opts)` returns an array of
records on success, or `nil, err`. A search error has class
`VectorSearchError`; router selection can return an existing CRUD router error.
Each record contains `id` (primary key parts), `bucket_id`, `vector`, and
`distance`. This result represents nearest-neighbor records and is distinct
from the tuple `rows`/`metadata` result of `crud.select`.

Options:

| Option | Default | Meaning |
| --- | --- | --- |
| `k` | required | Global result limit, 0 through 1024 |
| `L` | `k` | Candidate limit per shard, `k` through 1024 |
| `timeout` | 1 | Total request budget in seconds, greater than 0, at most 30 |
| `scope` | `{kind = 'all'}` | All buckets, one bucket, or a set of buckets |
| `algorithm_opts` | `{}` | Optional `ef_search`, 1 through 8192 |
| `vshard_router` | default | CRUD router instance or Cartridge group name |
| `max_participants` | 128 | Replicaset limit, 1 through 1024 |
| `max_pk_bytes` | 1024 | Encoded primary key size limit, at most 65536 |
| `max_response_bytes` | 33554432 | Router response budget, at most 32 MiB |

Scopes are `{kind = 'all'}`, `{kind = 'bucket', bucket_id = id}`, or
`{kind = 'buckets', bucket_ids = {id1, id2}}`. Bucket sets contain unique IDs;
an empty set and `k = 0` return an empty array without contacting storages.

Searches use masters. Full-cluster and bucket-set searches use protected
`map_callrw`; a single-bucket search uses protected `callrw`. They do not use
CRUD's ordinary per-replicaset map dispatcher, which does not hold the full
set of bucket references. Missing participants, incomplete/duplicate bucket
coverage, duplicate identities, inconsistent schemas, invalid payloads, and
timeouts fail the whole request. No partial result is returned.

Parameters come from the current storage schema on every request. The router
checks the metric, dimension, primary key comparator, collation fingerprint,
ICU version, and schema fingerprint across responses. Results are ordered by
distance, bucket ID, and primary key using Tarantool `key_def` comparisons.
Vectors use the VECTOR index's float32 input/float64 distance contract.
Approximate search quality depends on `L`, `ef_search`, and the index settings.
There is no cluster-wide snapshot across concurrent writes.

The storage function follows CRUD's trusted router identity model: the
transport user may execute `_crud.vector_search`, and the request carries the
router caller's effective user. The data select runs as that user and checks
the space read privilege. Bucket ownership is read as admin, so applications
do not need read access to `_bucket`. Transport credentials must be trusted;
they can impersonate a caller, as with `_crud.call_on_storage`.
There is no additional per-bucket authorization callback in this API.

`crud.cfg({stats = true})` records the operation under
`crud.stats(space_name).vector_search`, including success/error counts and
latency. Loading CRUD and initializing its roles remains possible without
VECTOR; attempting vector search then returns an unsupported-feature error.

## Verification

See [vector-search-report.md](vector-search-report.md) for the patchset split,
verification results, and deployment limits. The focused tests are in
`test/vector` and `test/unit/vector_unavailable_test.lua`. The full
three-replicaset fixture and runnable benchmark are in `test/vshard-vector`
and `perf/vector_search.lua`.
