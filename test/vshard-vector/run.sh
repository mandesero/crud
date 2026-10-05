#!/bin/sh
set -eu
: "${VSHARD_ROOT:?Set VSHARD_ROOT to a disposable pinned vshard checkout}"
: "${TARANTOOL_BIN:?Set TARANTOOL_BIN to the VECTOR-enabled executable}"
crud_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fixture="$crud_root/test/vshard-vector"
test_root="$VSHARD_ROOT/test"
cp "$fixture/localcfg.lua" "$VSHARD_ROOT/example/localcfg.lua"
cp "$fixture/vector-search.test.lua" "$test_root/router/"
cp "$fixture/vector-search.result" "$test_root/router/"
ln -sf ../lua_libs/storage_template.lua "$test_root/router/storage_3_a.lua"
export CRUD_VECTOR_FIXTURE="$fixture/fixture.lua"
export CRUD_VECTOR_LUA_PATH="$crud_root/?.lua;$crud_root/?/init.lua;$VSHARD_ROOT/?.lua;$VSHARD_ROOT/?/init.lua;${LUA_PATH:-;;}"
export PATH="$(dirname -- "$TARANTOOL_BIN"):$PATH"
cd "$test_root"
exec python3 test-run.py --suite router --executable "$TARANTOOL_BIN" \
    --vardir "${CRUD_VECTOR_VARDIR:-/tmp/crud-vector-cluster}" \
    -j 1 vector-search
