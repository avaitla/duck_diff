# Unit-testing DuckDB SQL with sqllogictest — `duckdb` CLI only

A copy-paste-into-your-project template for regression-testing your own DuckDB
SQL in the [sqllogictest][slt] format, needing **nothing but the `duckdb`
binary** — no source build, no `unittest` binary, no extension.

```sh
make setup    # checks that duckdb is on PATH
make test     # runs every tests/*.test
```

## How it works

sqllogictest is DuckDB's standard test format, but its usual runner — the
`unittest` binary — is only produced by building DuckDB from source and is not
distributed anywhere. So this template ships [`run_sqllogictest.sh`](run_sqllogictest.sh):
a small runner that interprets the common subset of the format by driving the
`duckdb` CLI. `make test` runs it and exits non-zero on the first mismatch, so a
drifted query fails your build.

Supported records (a blank line ends each one):

| Record | Meaning |
|--------|---------|
| `statement ok` + SQL | run it; fail if it errors |
| `statement error` + SQL | run it; fail if it *succeeds* |
| `query <types>` + SQL + `----` + rows | run it; compare output to the rows (tab-separated, one row per line, `NULL` for nulls) |
| `# …`, `require …`, `mode …` | ignored (kept so files also run under the real `unittest`) |

Tables persist across records within a file; each file gets a fresh database.
This covers most project test suites but is **not** the full sqllogictest spec
(no hashing, labels, sort modes, or per-engine `skipif`/`onlyif` logic).

## Writing a test

Drop a `.test` file in [`tests/`](tests). See
[`tests/revenue_by_customer.test`](tests/revenue_by_customer.test):

```
statement ok
CREATE TABLE orders (id INTEGER, customer VARCHAR, amount INTEGER);

statement ok
INSERT INTO orders VALUES (1,'alice',10), (2,'alice',5), (3,'bob',20);

query TI
SELECT customer, SUM(amount) FROM orders GROUP BY customer ORDER BY customer;
----
alice	15
bob	20
```

Columns in the expected block are separated by a single **tab**.

## Using duck_diff inside a test (optional)

The runner passes `-unsigned`, so if you've installed the [duck_diff](../)
extension you can `LOAD duck_diff;` and assert on a whole-table comparison
instead of hand-writing expected rows:

```
statement ok
LOAD duck_diff;

# expected vs actual must be identical on the primary key
query I
SELECT n_different + n_left_only + n_right_only
FROM table_diff_summary('FROM expected', 'FROM actual', pk := 'id');
----
0
```

[slt]: https://duckdb.org/dev/sqllogictest/intro
