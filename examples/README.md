# Testing your own SQL with `table_diff` — `duckdb` CLI only

A copy-paste-into-your-project demonstration of how to write your own
regression tests with duck_diff's `table_diff`, in the [sqllogictest][slt]
format, needing **nothing but the `duckdb` CLI** — no source build, no
`unittest` binary.

```sh
make setup    # checks that duckdb is on PATH
make test     # runs every tests/*.test
```

The examples assume the `duck_diff` extension is installed (see the
[top-level README](../README.md#install)); each test `LOAD`s it.

## The examples

| File | Shows |
|------|-------|
| [`tests/model_matches.test`](tests/model_matches.test) | The pass/fail idiom — a transformation is correct when `table_diff_summary` reports zero differences against a golden table. |
| [`tests/model_drift.test`](tests/model_drift.test) | When a model drifts, `table_diff` names the exact key and column that changed (all four `diff_status` values, plus `diff_data`). |

A test defines a golden table, runs your transformation, and asserts that
`table_diff_summary` finds no differences:

```
statement ok
LOAD duck_diff;

statement ok
CREATE TABLE actual_revenue AS
SELECT customer, SUM(amount)::INTEGER AS revenue FROM orders GROUP BY customer;

query IIII
SELECT n_different, n_left_only, n_right_only, n_identical
FROM table_diff_summary('FROM expected_revenue', 'FROM actual_revenue', pk := 'customer');
----
0	0	0	2
```

Columns in the expected block are separated by a single **tab**.

## How it runs

sqllogictest is DuckDB's standard test format, but its usual runner — the
`unittest` binary — is only produced by building DuckDB from source and is not
distributed anywhere. So this directory ships
[`run_sqllogictest.sh`](run_sqllogictest.sh): a small runner that interprets the
common subset of the format by driving the `duckdb` CLI. `make test` runs it and
exits non-zero on the first mismatch, so a drifted model fails your build.

Supported records (a blank line ends each one):

| Record | Meaning |
|--------|---------|
| `statement ok` + SQL | run it; fail if it errors |
| `statement error` + SQL | run it; fail if it *succeeds* |
| `query <types>` + SQL + `----` + rows | run it; compare output to the rows (tab-separated, one row per line, `NULL` for nulls) |
| `# …`, `require …`, `mode …` | ignored (kept so files also run under the real `unittest`) |

Tables persist across records within a file, and `LOAD`/`INSTALL` lines are
replayed before every record so the extension stays loaded. This covers most
project test suites but is **not** the full sqllogictest spec (no result
hashing, labels, sort modes, or per-engine `skipif`/`onlyif` logic).

[slt]: https://duckdb.org/dev/sqllogictest/intro
