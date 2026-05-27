# duck_diff

A DuckDB extension for diffing two relations (tables, sql queries etc) off a primary key. Given a
"left" and a "right" relation, it reports — per key — whether the row
**matched**, **differs**, or exists only on one side, and (for differing rows)
exactly which columns changed. It also supports a composite primary key, 
selecting a subset of columns to diff or ignore in diffing, and formatting as json 
columns or wide typed columns.

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

SELECT * FROM table_diff('users_v1', 'users_v2', pk := 'id') ORDER BY id;
```
```
┌───────┬─────────────┬──────────────┬──────────────────────────────────────┐
│  id   │ diff_status │ diff_columns │              diff_data               │
├───────┼─────────────┼──────────────┼──────────────────────────────────────┤
│   1   │ differs     │ [credits]    │ {"credits":{"left":100,"right":120}} │
│   2   │ matched     │ NULL         │ NULL                                 │
│   3   │ left_only   │ NULL         │ NULL                                 │
│   4   │ right_only  │ NULL         │ NULL                                 │
└───────┴─────────────┴──────────────┴──────────────────────────────────────┘
```
```sql
-- counts + percentages
SELECT * FROM table_diff_summary('users_v1', 'users_v2', pk := 'id');
```
```
┌───────────┬───────────┬─────────────┬──────────────┬─────────┬─────────────┬─────────────┬───────────────┬────────────────┐
│ n_matched │ n_differs │ n_left_only │ n_right_only │ n_total │ pct_matched │ pct_differs │ pct_left_only │ pct_right_only │
├───────────┼───────────┼─────────────┼──────────────┼─────────┼─────────────┼─────────────┼───────────────┼────────────────┤
│     1     │     1     │      1      │      1       │    4    │    25.0     │    25.0     │     25.0      │      25.0      │
└───────────┴───────────┴─────────────┴──────────────┴─────────┴─────────────┴─────────────┴───────────────┴────────────────┘
```
```sql
-- or a single yes/no
SELECT tables_equal('users_v1', 'users_v2', pk := 'id');   -- false
```

Prefer columns side by side instead of JSON? Add `wide := true` to expand each
compared column into `<col>_left` / `<col>_right` / `<col>_diff`:

```sql
SELECT id, diff_status, credits_left, credits_right, credits_diff
FROM table_diff('users_v1', 'users_v2', pk := 'id', wide := true) ORDER BY id;
```
```
┌───────┬─────────────┬──────────────┬───────────────┬──────────────┐
│  id   │ diff_status │ credits_left │ credits_right │ credits_diff │
├───────┼─────────────┼──────────────┼───────────────┼──────────────┤
│   1   │ differs     │      100     │      120      │ true         │
│   2   │ matched     │       50     │       50      │ false        │
│   3   │ left_only   │       75     │     NULL      │ true         │
│   4   │ right_only  │     NULL     │       10      │ true         │
└───────┴─────────────┴──────────────┴───────────────┴──────────────┘
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
LOAD '/Users/avaitla/duck_diff.duckdb_extension';
SELECT * FROM table_diff('a', 'b', pk := 'id');
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

DuckDB is a great fit since it has connectors to many databases and can run 
locally and within customers VPC/private environment.

## Functions

See [docs/functions.md](docs/functions.md) for the full reference.

| Function | Returns | Purpose |
|----------|---------|---------|
| `table_diff(left, right, pk := …)` | table | one row per key: key column(s), `diff_status`, `diff_data` |
| `table_diff_summary(left, right, pk := …)` | one row | counts (and percentages) per status |
| `tables_equal(left, right, pk := …)` | BOOLEAN | true iff every key matched |
| `schema_diff(left, right)` | table | per-column name/type comparison: `column_name`, `left_type`, `right_type`, `status` |

## `table_diff` parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `left`, `right` | VARCHAR | Relation expressions — a table/view name, a table function, or a `(subquery)`. |
| `pk` | VARCHAR \| LIST | **Required.** Primary key column(s); a string or a list. |
| `additional_pk` | LIST | Extra key columns appended to `pk` (composite key). |
| `compare` | VARCHAR | `'strict'` (default; identical column names+types required) or `'intersect'` (only common, same-typed columns). |
| `columns` | LIST | Restrict the compared (non-key) columns to this list. |
| `ignore` | LIST | Exclude these columns from comparison. |
| `context` | LIST | Pull these columns from both sides into `left_context`/`right_context`; use `['*']` for every non-key, non-compared column. |
| `wide` | BOOLEAN | Expand each compared column into `<c>_left`/`<c>_right`/`<c>_diff` instead of JSON `diff_data`. |
| `prefix` | VARCHAR | Prefix for the meta columns (default `'diff_'`); change it if a key column would collide. |

**Output:** the key column(s) under their original names (so you can
`JOIN … USING (…)`), then `diff_status` (`matched` / `differs` / `left_only` /
`right_only`), then `diff_data` — a JSON object of only the changed columns,
`{"col": {"left": …, "right": …}}`, types preserved (or the expanded
`_left`/`_right`/`_diff` columns in wide mode). Comparison is NULL-safe
(`IS NOT DISTINCT FROM`, so `NULL` equals `NULL`).

See [docs/functions.md](docs/functions.md) for the full reference (all functions,
`schema_diff`, and recipes like deriving `ignore`/`columns` from a query).

## Diffing external sources (BigQuery, Postgres, CSV, …)

Because the relation arguments are strings spliced in after `FROM`, any table
function from another extension works. Use DuckDB's dollar-quoting (`$$…$$`) so
the inner quotes need no escaping:

```sql
INSTALL bigquery FROM community; LOAD bigquery;
ATTACH 'project=my-project' AS bq (TYPE bigquery, READ_ONLY);  -- uses local ADC

SELECT * FROM table_diff(
  $$ bigquery_query('bq', 'SELECT * FROM snapshots.invoices_20260101') $$,
  $$ bigquery_query('bq', 'SELECT * FROM snapshots.invoices_20260526') $$,
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

SELECT * FROM table_diff_summary('jan', 'may', pk := 'id');         -- counts + percentages
SELECT * FROM table_diff('jan', 'may', pk := 'id') WHERE diff_status='differs' LIMIT 20;
-- which columns change most often:
SELECT col, count(*) FROM (
  SELECT unnest(diff_columns) AS col
  FROM table_diff('jan', 'may', pk := 'id') WHERE diff_status='differs'
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
SELECT * FROM table_diff('a', 'b', pk := 'id');
```

> **Installing without building:** each [GitHub Release](https://github.com/avaitla/duck_diff/releases)
> attaches signed, per-platform `.duckdb_extension` binaries (see
> [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)). Download the one for your
> platform, **saved as `duck_diff.duckdb_extension`** (DuckDB derives the
> extension name from the filename), then `LOAD` it under `-unsigned`:
> ```sh
> curl -L -o duck_diff.duckdb_extension \
>   https://github.com/avaitla/duck_diff/releases/download/v0.1.0/duck_diff-v1.5.2-osx_arm64.duckdb_extension
> duckdb -unsigned -c "LOAD 'duck_diff.duckdb_extension'; SELECT * FROM table_diff('a','b', pk:='id');"
> ```
