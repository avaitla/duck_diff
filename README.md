# duck_diff

A DuckDB extension for diffing two relations (tables, SQL queries, etc.) off a primary key. Given a
"left" and a "right" relation, it reports — per key — whether the row is
**identical**, **different**, or exists only on one side, and exactly what
changed. Each result row carries both a JSON `diff_data` summary of the changed
columns *and* per-column expanded columns (`<c>_left` / `<c>_right` /
`<c>_diff_status`). It also supports a composite primary key and selecting a
subset of columns to diff or ignore.

## Quick start

Get a DuckDB shell with `duck_diff` loaded (see [Install](#install) or
[Building](#building)), then create two sample snapshots and diff them:

```sql
CREATE TABLE users_v1 AS SELECT * FROM (VALUES
    (1, 'Ada',   'ada@x.com',   100),
    (2, 'Linus', 'linus@x.com',  50),
    (3, 'Grace', 'grace@x.com',  75)
) t(id, name, email, credits);

CREATE TABLE users_v2 AS SELECT * FROM (VALUES
    (1, 'Ada',   'ada@x.com',   120),   -- credits changed
    (2, 'Linus', 'linus@x.com',  50),   -- unchanged
    (4, 'Mike',  'mike@x.com',   10)    -- new (id 3 removed)
) t(id, name, email, credits);

SELECT id, diff_status, diff_data, credits_left, credits_right, credits_diff_status
FROM table_diff('FROM users_v1', 'FROM users_v2', pk := 'id') ORDER BY id;
```
```
┌────┬─────────────┬──────────────────────────────────────┬──────────────┬───────────────┬─────────────────────┐
│ id │ diff_status │              diff_data               │ credits_left │ credits_right │ credits_diff_status │
├────┼─────────────┼──────────────────────────────────────┼──────────────┼───────────────┼─────────────────────┤
│ 1  │ different   │ {"credits":{"left":100,"right":120}} │ 100          │ 120           │ different           │
│ 2  │ identical   │ NULL                                 │ 50           │ 50            │ identical           │
│ 3  │ left_only   │ NULL                                 │ 75           │ NULL          │ left_only           │
│ 4  │ right_only  │ NULL                                 │ NULL         │ 10            │ right_only          │
└────┴─────────────┴──────────────────────────────────────┴──────────────┴───────────────┴─────────────────────┘
```

Each row gives you two views of the same diff — pick whichever fits:

- **`diff_data`** — a compact JSON of just the changed columns,
  `{"col": {"left": …, "right": …}}` (and `json_keys(diff_data)` lists which
  columns changed).
- **Expanded columns** — for each compared column: `<c>_left`, `<c>_right`
  (native types), and `<c>_diff_status` (`identical` / `different` /
  `left_only` / `right_only`). Real typed columns, so you can filter and compute
  on them directly.

```sql
-- counts + percentages
SELECT * FROM table_diff_summary('FROM users_v1', 'FROM users_v2', pk := 'id');
```
```
┌───────────┬───────────┬─────────────┬──────────────┬─────────┬─────────────┬─────────────┬───────────────┬────────────────┐
│ n_identical │ n_different │ n_left_only │ n_right_only │ n_total │ pct_identical │ pct_different │ pct_left_only │ pct_right_only │
├───────────┼───────────┼─────────────┼──────────────┼─────────┼─────────────┼─────────────┼───────────────┼────────────────┤
│     1     │     1     │      1      │      1       │    4    │    25.0     │    25.0     │     25.0      │      25.0      │
└───────────┴───────────┴─────────────┴──────────────┴─────────┴─────────────┴─────────────┴───────────────┴────────────────┘
```
```sql
-- or a single yes/no, simulated from the summary
SELECT n_different + n_left_only + n_right_only = 0
FROM table_diff_summary('FROM users_v1', 'FROM users_v2', pk := 'id');   -- false
```

## Install

Each [GitHub Release](https://github.com/avaitla/duck_diff/releases) attaches a
signed binary per platform. Download the one matching your DuckDB version and
platform, **saved as `duck_diff.duckdb_extension`** (DuckDB derives the
extension name from the filename), then load it under `-unsigned` (the binaries
are signed with a third-party key, so unsigned extensions must be enabled — a
launch flag, not a `SET`):

```sh
curl -L -o duck_diff.duckdb_extension \
  https://github.com/avaitla/duck_diff/releases/download/v0.1.0/duck_diff-v1.5.2-osx_arm64.duckdb_extension
duckdb -unsigned
```

Load it with the full filepath:

```sql
LOAD '/path/to/duck_diff.duckdb_extension';
SELECT * FROM table_diff('FROM a', 'FROM b', pk := 'id');
```

Platforms: `linux_amd64`, `linux_arm64`, `osx_amd64`, `osx_arm64`,
`windows_amd64`. Prefer to build it yourself? See [Building](#building). Details
and signature verification: [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Use cases

- **Refactoring SQL** (possibly even onto a new database) and ensuring the
  results are the same.
- **Capturing the differences** between snapshots or points in time.
- **Replication integrity** — spot-check that a replica matches its source, in
  the spirit of `pt-table-checksum`.
- **Safe AI-assisted changes** — give a coding agent like Claude a ground-truth
  check that a refactor or data-modeling change produced identical results, so
  it can iterate on transformations safely instead of guessing.
- **Regression tests in CI** — assert in a test suite that a model's output
  still matches its golden snapshot, failing the build when it drifts. See
  [examples/](examples/) for runnable `.test` files and a GitHub Actions snippet.

DuckDB is a great fit since it has connectors to many databases and can run 
locally and within customers VPC/private environment.

## Functions

See [docs/functions.md](docs/functions.md) for the full reference.

| Function | Returns | Purpose |
|----------|---------|---------|
| `table_diff(left, right, pk := …)` | table | one row per key: key column(s), `diff_status`, `diff_data` |
| `table_diff_summary(left, right, pk := …)` | one row | counts (and percentages) per status |
| `schema_diff(left, right)` | table | per-column name/type comparison: `column_name`, `left_type`, `right_type`, `status` |

## `table_diff` parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `left`, `right` | VARCHAR | Query strings, written as you would in SQL: a `FROM …` clause or a full `SELECT … FROM …`. E.g. `'FROM orders'`, `'FROM read_csv(''x.csv'')'`, `'SELECT id, amount FROM orders WHERE region = ''EU'''`. A bare name like `'orders'` is rejected. |
| `pk` | VARCHAR \| LIST | **Required.** Primary key column(s); a string or a list. |
| `require_matching_columns` | BOOLEAN | Default `true`: both relations must have identical columns (names+types), else error. Set `false` to compare only common columns. |
| `upcast_types` | BOOLEAN | Default `false`. Set `true` (with `require_matching_columns := false`) to reconcile differing types via their common super-type, e.g. BIGINT vs INTEGER — see [function reference](docs/functions.md#cross-type-comparison). |
| `numeric_tolerance` | DOUBLE | Treat numbers within this band as equal (`abs(left-right) <= tol`); compared columns only. |
| `timestamp_precision` | VARCHAR | Truncate timestamp columns with `date_trunc(part, …)` before comparing, e.g. `'second'`. |
| `null_equals_empty` | BOOLEAN | Default `false`. Treat `NULL` and `''` as equal for VARCHAR compared columns. |
| `columns` | LIST | Restrict the compared (non-key) columns to this list. |
| `ignore` | LIST | Exclude these columns from comparison. |
| `context` | LIST | Also expand these **non-compared** columns as `<c>_left`/`<c>_right` (no `_diff_status`). Use `['*']` for every non-key column, which surfaces the full row for `left_only`/`right_only` rows. |
| `prefix` | VARCHAR | Prefix for the meta columns (default `'diff_'`); change it if a key column would collide. |

**Output columns, in order:**

1. The **key column(s)**, under their original names (so you can `JOIN … USING (…)`).
2. **`diff_status`** — `identical`, `different`, `left_only`, or `right_only`.
3. **`diff_data`** — JSON of just the changed columns, types preserved.
4. The **expanded columns** — `<c>_left`, `<c>_right`, `<c>_diff_status` per compared column.

Comparison is NULL-safe: `NULL` equals `NULL`.

See [docs/functions.md](docs/functions.md) for the full reference (all functions,
`schema_diff`, and recipes like deriving `ignore`/`columns` from a query).

## Diffing external sources (BigQuery, Postgres, CSV, …)

Because each relation argument is a query string, any table function from
another extension works — just write it as a `FROM …` clause. Use DuckDB's
dollar-quoting (`$$…$$`) so the inner quotes need no escaping:

```sql
INSTALL bigquery FROM community; LOAD bigquery;
ATTACH 'project=my-project' AS bq (TYPE bigquery, READ_ONLY);  -- uses local ADC

SELECT * FROM table_diff(
  $$ FROM bigquery_query('bq', 'SELECT * FROM snapshots.invoices_20260101') $$,
  $$ FROM bigquery_query('bq', 'SELECT * FROM snapshots.invoices_20260526') $$,
  pk := 'id',
  ignore := ['updated_at', 'updated_by']   -- drop metadata churn from the comparison
);
```

### Performance & caching

DuckDB has no automatic cross-query result cache, and `table_diff` references
each side more than once internally (the join plus the duplicate-key check). For
an expensive remote source, **materialize each side once** into a local table —
that local copy is your cache, and every subsequent diff/summary is free of the
remote scan:

```sql
-- run with a file-backed db (e.g. `duckdb cache.db`) to persist across sessions
CREATE TABLE IF NOT EXISTS jan AS
  SELECT * FROM bigquery_query('bq', 'SELECT * FROM snapshots.invoices_20260101');
CREATE TABLE IF NOT EXISTS may AS
  SELECT * FROM bigquery_query('bq', 'SELECT * FROM snapshots.invoices_20260526');

SELECT * FROM table_diff_summary('FROM jan', 'FROM may', pk := 'id');         -- counts + percentages
SELECT * FROM table_diff('FROM jan', 'FROM may', pk := 'id') WHERE diff_status='different' LIMIT 20;
-- which columns change most often:
SELECT col, count(*) FROM (
  SELECT unnest(json_keys(diff_data)) AS col
  FROM table_diff('FROM jan', 'FROM may', pk := 'id') WHERE diff_status='different'
) GROUP BY col ORDER BY count(*) DESC;
```

`CREATE TABLE IF NOT EXISTS` scans the source only the first time. Within a
single query you can also force one shared scan with a `WITH x AS MATERIALIZED
(...)` CTE.

## Building

The repo vendors DuckDB and the build tooling as submodules, so a clone +
`make` produces a DuckDB shell with `duck_diff` preloaded:

```sh
git clone --recurse-submodules https://github.com/avaitla/duck_diff
cd duck_diff
GEN=ninja make            # first build compiles DuckDB; needs cmake + ninja
./build/release/duckdb    # this shell already has duck_diff loaded

build/release/test/unittest "test/sql/*"   # run the SQL test suite
```
(Cloned without submodules? `git submodule update --init --recursive`.)

The extension generates SQL using `json_object` / `json_merge_patch`, so the
bundled `json` extension is required (built in automatically for tests).

### Using it in another DuckDB

The build also emits a loadable binary at
`build/release/extension/duck_diff/duck_diff.duckdb_extension`. It's locally
built (unsigned), so load it with unsigned extensions enabled:

```sh
duckdb -unsigned
```
```sql
LOAD 'build/release/extension/duck_diff/duck_diff.duckdb_extension';
SELECT * FROM table_diff('FROM a', 'FROM b', pk := 'id');
```

> **Installing without building:** each [GitHub Release](https://github.com/avaitla/duck_diff/releases)
> attaches signed, per-platform `.duckdb_extension` binaries (see
> [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)). Download the one for your
> platform, **saved as `duck_diff.duckdb_extension`** (DuckDB derives the
> extension name from the filename), then `LOAD` it under `-unsigned`:
> ```sh
> curl -L -o duck_diff.duckdb_extension \
>   https://github.com/avaitla/duck_diff/releases/download/v0.1.0/duck_diff-v1.5.2-osx_arm64.duckdb_extension
> duckdb -unsigned -c "LOAD 'duck_diff.duckdb_extension'; SELECT * FROM table_diff('FROM a','FROM b', pk:='id');"
> ```

## TODO

- **Projection pushdown.** The generated query reads every column of each
  relation (`SELECT __t.* …`), even columns that are ignored or never compared.
  At bind time we already know the exact set the diff needs (keys + compared +
  context columns), so we could project just those instead. DuckDB would push
  that narrowed column list into the scan, so native table / Parquet / remote
  scanners (Postgres, MySQL, BigQuery) fetch only the needed columns — fewer
  bytes over the wire, identical results. Biggest win for wide remote tables;
  small for local columnar scans. (No help when the input is a `SELECT *`
  passthrough — reference the table object instead.)

## License

[MIT](LICENSE) Bundles DuckDB, which is also MIT-licensed.
