# Examples — using duck_diff in CI

These are runnable [sqllogictest][slt] files showing how to assert, in a test
suite, that two relations match (or drift in a bounded way). sqllogictest is
DuckDB's own test format, run by the `unittest` binary the duck_diff build
produces — no extra harness.

| File | Shows |
|------|-------|
| [`test/sql/model_matches.test`](test/sql/model_matches.test) | The pass/fail idiom: a transformation's output is correct iff `table_diff_summary` reports `n_different = n_left_only = n_right_only = 0`. |
| [`test/sql/model_diff_detail.test`](test/sql/model_diff_detail.test) | When something drifts, `table_diff` names the exact key and column — exercises all four `diff_status` values (`identical` / `different` / `left_only` / `right_only`). |
| [`test/sql/summary_counts.test`](test/sql/summary_counts.test) | Tolerance thresholds: assert on `pct_different` (e.g. fail only when more than X% of keys differ) instead of demanding exact equality. |

## Running them

Build the extension once from the repo root (see
[Building](../README.md#building)), then from this directory:

```sh
make test
```

The [`Makefile`](Makefile) just points the standard `unittest` runner at this
directory (`unittest --test-dir . "test/*"`), which discovers the `.test` files
under [`test/`](test). It exits non-zero on the first failing assertion, so a
drifted model fails the build — that's the whole CI story.

To diff a live source (BigQuery, Postgres, a CSV, …) instead of the in-test
fixtures, swap the `'FROM expected'` / `'FROM actual'` strings for real
queries — see
[Diffing external sources](../README.md#diffing-external-sources-bigquery-postgres-csv-).

[slt]: https://duckdb.org/dev/sqllogictest/intro
