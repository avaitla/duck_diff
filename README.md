# duck_diff

A focused DuckDB extension for diffing two relations on a primary key. Given a
"left" and a "right" relation, it reports — per key — whether the row
**matched**, **differs**, or exists only on one side, and (for differing rows)
exactly which columns changed.

```sql
LOAD duck_diff;

FROM table_diff('orders_before', 'orders_after', pk := 'order_id');
```

| order_id | diff_status | diff_data |
|----------|-------------|-----------|
| 1 | matched | NULL |
| 3 | left_only | NULL |
| 5 | differs | `{"amount":{"left":10,"right":12}}` |
| 7 | right_only | NULL |

The two relations are passed as **strings** — anything valid after `FROM`: a
table/view name, a table function, or a parenthesized subquery. So named tables,
CSV/Parquet, and ad-hoc queries all work:

```sql
FROM table_diff('read_csv(''before.csv'')', 'read_csv(''after.csv'')', pk := 'id');
FROM table_diff('(SELECT * FROM orders WHERE region = ''US'')', 'orders_v2', pk := 'id');
```

## Quick start

Get a DuckDB shell with `duck_diff` loaded (see [Building](#building)), then
create two sample snapshots and diff them:

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

FROM table_diff('users_v1', 'users_v2', pk := 'id') ORDER BY id;
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
-- counts + percentages, or a single yes/no
FROM table_diff_summary('users_v1', 'users_v2', pk := 'id');
SELECT tables_equal('users_v1', 'users_v2', pk := 'id');   -- false
```

## Use cases

- **Refactoring SQL** (possibly even onto a new database) and ensuring the
  results are the same.
- **Capturing what changed** between snapshots or points in time.
- **Replication integrity** — spot-check that a replica matches its source, in
  the spirit of `pt-table-checksum`.
- **Safe AI-assisted changes** — give a coding agent like Claude a ground-truth
  check that a refactor or data-modeling change produced identical results, so
  it can iterate on transformations safely instead of guessing.

## Functions

See [docs/functions.md](docs/functions.md) for the full reference.

| Function | Returns | Purpose |
|----------|---------|---------|
| `table_diff(left, right, pk := …)` | table | one row per key: key column(s), `diff_status`, `diff_data` |
| `table_diff_summary(left, right, pk := …)` | one row | counts (and percentages) per status |
| `tables_equal(left, right, pk := …)` | BOOLEAN | true iff every key matched |
| `schema_diff(left, right)` | table | per-column name/type comparison: `column_name`, `left_type`, `right_type`, `status` |

## Key features

- **Keys**: `pk := 'id'` (single) or `pk := 'region', additional_pk := ['id']`
  (composite). Key columns are emitted under their **original names**, so you can
  join the diff back to the source: `... JOIN orders USING (region, id)`.
- **Status**: `matched`, `differs`, `left_only`, `right_only`. NULL-safe
  comparison (`IS NOT DISTINCT FROM`, so `NULL` equals `NULL`).
- **`diff_data`** (JSON): for `differs` rows, only the columns that changed, as
  `{"col": {"left": …, "right": …}}`, with native types preserved.
- **Wide mode** (`wide := true`): expand each compared column into
  `<c>_left` / `<c>_right` / `<c>_diff` (and context into `<c>_left`/`<c>_right`)
  as real typed columns instead of JSON.
- **Schema policy**: `compare := 'strict'` (default — relations must match) or
  `'intersect'` (compare only common, same-typed columns). Refine with
  `columns := [...]` / `ignore := [...]`.
- **Context**: `context := ['name']` pulls those columns from both sides into
  `left_context` / `right_context` JSON columns — handy for understanding why a
  row is `left_only`/`right_only`. `context := ['*']` pulls in every non-key
  column not already compared; with `wide := true` that yields a full
  side-by-side of all columns for dashboards.
- **Collisions**: meta columns default to a `diff_` prefix; override with
  `prefix := 'cmp_'` if a key column would clash.
- **Schema diff + reuse**: `schema_diff('a','b')` reports per-column name/type
  matches. Feed the result straight into a diff via a variable (a named argument
  can't hold a subquery, so capture the list and pass `getvariable`):
  ```sql
  SET VARIABLE mismatch = (
    SELECT list(column_name) FROM schema_diff('a','b') WHERE status <> 'matched'
  );
  FROM table_diff('a','b', pk := 'id', ignore := getvariable('mismatch'));
  ```

## Diffing external sources (BigQuery, Postgres, CSV, …)

Because the relation arguments are strings spliced in after `FROM`, any table
function from another extension works. Use DuckDB's dollar-quoting (`$$…$$`) so
the inner quotes need no escaping:

```sql
INSTALL bigquery FROM community; LOAD bigquery;
ATTACH 'project=my-project' AS bq (TYPE bigquery, READ_ONLY);  -- uses local ADC

FROM table_diff(
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

FROM table_diff_summary('jan', 'may', pk := 'id');                 -- counts + percentages
FROM table_diff('jan', 'may', pk := 'id') WHERE diff_status='differs' LIMIT 20;
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
FROM table_diff('a', 'b', pk := 'id');
```

> **Installing without building:** `INSTALL` needs prebuilt, per-platform
> binaries — you can't `INSTALL` straight from this source repo. Cutting a
> GitHub Release builds, signs, and publishes them to GitHub Pages (see
> [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)); users then install with:
> ```sql
> SET custom_extension_repository = 'https://avaitla.github.io/duck_diff';
> SET allow_unsigned_extensions = true;
> INSTALL duck_diff; LOAD duck_diff;
> ```

## Status

Single relation argument per DuckDB's table-function limit drives the
string-argument design (same pattern as the built-in `query()` /
`query_table()`). See [docs/DESIGN.md](docs/DESIGN.md) for the full design and
rationale.
