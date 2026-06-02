# Examples — using duck_diff in CI

These are runnable [sqllogictest][slt] files showing how to assert, in a test
suite, that two relations match (or drift in a bounded way). They're the same
format DuckDB itself uses, so the project's own `unittest` binary runs them
directly — no extra harness.

| File | Shows |
|------|-------|
| [`sql/model_matches.test`](sql/model_matches.test) | The pass/fail idiom: a transformation's output is correct iff `table_diff_summary` reports `n_different = n_left_only = n_right_only = 0`. |
| [`sql/model_diff_detail.test`](sql/model_diff_detail.test) | When something drifts, `table_diff` names the exact key and column — exercises all four `diff_status` values (`identical` / `different` / `left_only` / `right_only`). |
| [`sql/summary_counts.test`](sql/summary_counts.test) | Tolerance thresholds: assert on `pct_different` (e.g. fail only when more than X% of keys differ) instead of demanding exact equality. |

## Running them

The `.test` format is understood by DuckDB's `unittest` binary, which the
duck_diff build produces. From a built checkout (see
[Building](../README.md#building)):

```sh
build/release/test/unittest "examples/sql/*"
```

## In CI

Drop your own `.test` files alongside these, then run `unittest` against them in
a workflow step. A minimal GitHub Actions job:

```yaml
- name: build duck_diff
  run: GEN=ninja make

- name: assert models match
  run: build/release/test/unittest "examples/sql/*"
```

The step exits non-zero on the first failing assertion, so a drifted model
fails the build. To diff a live source (BigQuery, Postgres, a CSV, …) instead of
the in-test fixtures, swap the `'FROM expected'` / `'FROM actual'` strings for
real queries — see [Diffing external sources](../README.md#diffing-external-sources-bigquery-postgres-csv-).

[slt]: https://duckdb.org/dev/sqllogictest/intro
