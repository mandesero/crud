# Distributed VECTOR benchmark

Run the three-replicaset fixture with `CRUD_VECTOR_BENCH_SCRIPT` pointing
at `perf/vector_search.lua` and `CRUD_VECTOR_BENCH_OUTPUT` naming a JSON
output file. See [vector-search-report.md](vector-search-report.md) for the
complete command and pinned dependencies.

The benchmark inserts 300 deterministic records: 150 distributed among
buckets and 150 in bucket 1. Its five profiles use 30 requests each,
dimension 2, L2, k=5, ef_search=128 and L=10 or 20. The JSON includes a
dataset checksum, participant count, total and dispatch p50/p95/p99,
post-ref budget consumption, merge/validation time, reply bytes, router
GC memory and elapsed migration time during a protected search.

The full fixture separately checks Recall@5 >=0.8 against a global exact
f32 oracle for three queries after concurrent DML. The latency profiles
measure overhead; they do not measure recall independently.

These exploratory Debug thresholds were fixed for the original small
fixture before its final acceptance rerun:

| Profile | p99 latency |
| --- | ---: |
| All buckets, three replicasets | <=50 ms |
| Single bucket | <=10 ms |
| Three-bucket set | <=20 ms |

The original three-bucket profile reached 13.58 ms when it incorrectly
shared the single-bucket 10 ms threshold. The separate 20 ms threshold
was fixed before the original final rerun. Keep this history when comparing
the port. Fixed request sequences and 30 observations per profile do not
establish production capacity or a concurrency SLO.
