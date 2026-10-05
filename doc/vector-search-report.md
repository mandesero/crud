# CRUD VECTOR patchset report

Date: 2026-10-05. CRUD base:
`13523e3719e4d49945197b35b884e6d65dd4ed92`.
Native Tarantool code tree:
`fae93a25e89211a3fb39ed1684b942a217eabf66` (GCC 13.3 Debug).
The tested binary identifies the identical tree before commit-message
normalization as `3.9.0-entrypoint-185-g8bd63fc90`.

## Repository split

Tarantool owns the numeric kernel, ANN API, Flat oracle, quota-aware
USearch adapter, memtx VECTOR index, atomic DML, MVCC, DDL, local
NEIGHBOR select, diagnostics, stat/rebuild, recovery and native tests.
The private ICU version helper stays in Tarantool because its native
collations use ICU. USearch remains pinned at
`0355958c08b22c642fc38ece00cd30646243b141`.

CRUD owns the yielding storage endpoint, router validation and merge,
wire schema/PK/collation metadata, public API, stats and role integration.
Its ordinary roles register `_crud.vector_search`; manual logical-index
registration and a separate vector storage role are unnecessary.
The API is `crud.vector_search(space_name, index_name, query, opts)` and
follows CRUD's trusted router identity model. See the
[API guide](vector-search.md) for its privileges and bounds.

Generic bucket-reference context and remaining-time propagation stay in
vshard at `674cda708d957cc145aa4f0622804bb5c2f8007a`.

The rebuilt Tarantool series removes the three embedded `vector_search.*`
modules, CMake/module registration, duplicate local storage/router tests,
three-replicaset fixture, distributed benchmark and result, and obsolete
storage-role changelog. Its native source tree is otherwise unchanged.
CRUD now contains the full fixture, benchmark, workflow and distributed
measurement history. The two series finish with their respective reports.

The CRUD commits separate API/storage/router integration and focused tests,
the full cluster fixture, distributed benchmark, companion CI, the
child-process dependency regression fix, and this report. Backup branches preserve the previous published patchsets.

## Reproduce

Build the companion Tarantool code commit with its recursive submodules:

```sh
git submodule update --init --recursive
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --target tarantool -j 8
```

In CRUD, install its `checks` and `errors` dependencies and Luatest. Put
those dependencies on `LUA_PATH`, then prepend both checkouts:

```sh
export TARANTOOL_BIN=/path/to/tarantool/build/src/tarantool
export VSHARD_ROOT=/path/to/disposable-vshard-checkout
# VSHARD_ROOT must be at the pinned commit above, with test-run initialized.
export PATH="$(dirname "$TARANTOOL_BIN"):$PATH"
export LUA_PATH="$PWD/?.lua;$PWD/?/init.lua;$VSHARD_ROOT/?.lua;$VSHARD_ROOT/?/init.lua;${LUA_PATH:-;;}"
"$TARANTOOL_BIN" /path/to/luatest/bin/luatest -v test/vector \
  test/unit/vector_unavailable_test.lua test/unit/privileges_test.lua
export CRUD_VECTOR_BENCH_SCRIPT="$PWD/perf/vector_search.lua"
export CRUD_VECTOR_BENCH_OUTPUT=/tmp/crud-vector-search.json
test/vshard-vector/run.sh
```

The launcher copies its fixture into the disposable vshard checkout and
preserves dependency paths through test-run's environment reset. It uses
one router and three replicasets, with replicas in the first two.
Omit the two benchmark variables to run only the correctness fixture.
Python test-run dependencies, including `tarantool==0.12`, are required.
The companion workflow records pinned source commits and dependency setup.

## Verification

On the selected Ubuntu 24.04 x86_64 host, using the native-only binary:

- 12/12 focused tests passed: eight VECTOR cases, one unavailable-feature
  compatibility case and three existing CRUD caller-identity cases.
- The full three-replicaset fixture passed. It covers all scopes, delayed
  refs, concurrent DML with an exact f32 Recall@5 >=0.8 oracle, migration
  with leftover tuples and protected in-flight search, schema/protocol
  mismatch, reply overflow, timeout, promotion, snapshot/restart,
  storage errors and router disconnect/reconnect.
- LuaCheck 0.25.0 reported zero warnings/errors in all 15 changed Lua files.
- Tarantool's four ANN units and eight native Lua suites passed separately.
- The earlier stock build compatibility run passed its one case and skipped
  all eight VECTOR cases. Production CRUD code is unchanged since that run.

### CI child-process dependency regression

The ordinary CRUD CI exposed a missing `luatest` module in the server
started by `vector_unavailable_test.lua`. LuaRocks supplies search paths
to its runner process, while a bare child Tarantool does not inherit the
runner's `package.path`. Each new VECTOR test now passes project paths
and the parent Lua/Lua C search paths explicitly in the server environment.

The failure was reproduced on Ubuntu with Luatest 1.0.1 and no `LUA_PATH`
environment variable: dependencies were added only to the parent
`package.path`. Before the fix, the compatibility case failed with the
reported module error. After the fix, all 12 focused cases passed on the
VECTOR build. On stock `3.9.0-entrypoint-202-g72deda106`, the compatibility
case passed and all eight VECTOR cases skipped. LuaCheck 0.25.0 found no
warnings/errors in the four changed test files. The native implementation
and public CRUD API are unchanged by this fix.

## Distributed measurements

[crud-split-isolated.json](vector-search-results/crud-split-isolated.json)
contains the final isolated rerun: 300 deterministic records, five
profiles with 30 requests each, k=5, dimension=2, L2, ef_search=128,
three replicasets, Debug build on eight virtual Icelake CPUs.
The [thresholds](vector-search-benchmarks.md) are unchanged.

| Profile | p50 ms | p99 ms | Reply bytes p99 |
| --- | ---: | ---: | ---: |
| uniform_all_L10 | 12.33 | 21.65 | 11157 |
| skew_all_L10 | 6.32 | 10.94 | 11146 |
| skew_all_L20 | 8.66 | 39.45 | 12852 |
| single_bucket | 1.43 | 4.91 | 797 |
| bucket_set | 2.65 | 7.43 | 1541 |

All profiles returned five records and satisfied the isolated latency
thresholds. Protected migration took 0.315 seconds while the search held
its bucket reference. Router GC memory is an observation before/after,
not a resident-memory bound.

[crud-split-concurrent.json](vector-search-results/crud-split-concurrent.json)
preserves the first run, which overlapped the eight native test suites.
Its one-bucket p99 was 12.90 ms and exceeded the 10 ms threshold. The
isolated rerun resolved that specific interference; both runs are kept.
[legacy-embedded.json](vector-search-results/legacy-embedded.json) is the
original pre-port distributed acceptance result from the embedded Lua
package, not a measurement of CRUD. These small fixed-sequence Debug
runs do not establish production throughput or a general performance gain.

## RFC revision 4 companion pin

The companion VECTOR workflow now pins native code commit
`ce2266beca78a77858b954fc50b5fad3ab6130ec`. It includes the corrected
`slots.pending_rebuild` statistics, numeric contract, resource limits,
cumulative local-search duration and ordinary-memtx tuple-binding GC.
CRUD's 12 focused tests passed with this corrected binary on the selected
Ubuntu host. The distributed protocol and production CRUD code are unchanged.
The full fixture and benchmark were not repeated for this diagnostic update;
the measurements above remain historical results of the earlier split.

## Limits

The hosted companion VECTOR workflow and full Cartridge role matrix
have not been verified. Ordinary CRUD CI started after publication; this
section records the targeted local reproduction and fix, not a green
result for the complete hosted matrix. The focused suites validate a supplied vshard router
instance; they do not establish every deployment/version combination.
Search remains approximate and has no cluster-wide snapshot under DML.
Transport credentials can impersonate the carried user under CRUD's
existing trusted-router model. There is no per-bucket authorization
callback. A complete sanitizer run of the Lua integration is not available.
