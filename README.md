# 🦆 duck_diff

Two tables — maybe two entirely different databases — one question: **are
these actually the same rows?**

`duck_diff` is a DuckDB extension that diffs two relations off a primary key,
per row and per column. Every key gets a verdict (`identical` / `different` /
`left_only` / `right_only`), a JSON summary of exactly which columns changed
(`diff_data`), and typed `<col>_left` / `<col>_right` / `<col>_diff_status`
columns you can filter and compute on. Composite keys, column subsets, and
cross-engine tolerances included.

Because each side is just a query string, the two relations can live in
**different systems** — Postgres, MySQL, ClickHouse, BigQuery, Snowflake,
Iceberg, Delta, MongoDB, plain Parquet/CSV files, anything DuckDB can reach —
and everything runs locally in your DuckDB process; your data never leaves
your pond.

And since the verdict is deterministic (`n_total = n_identical`, true or
false), it's a validation step **Claude can run in loops** (e.g. with Claude
Code's [`/goal`](https://code.claude.com/docs/en/goal)): safely refactor a
model, optimize a slow query, or transpile SQL to another dialect, checking
its own correctness after every change and stopping only when the diff comes
back clean.

**[Website & recipe builder](https://avaitla.github.io/duck_diff/)** ·
[Function reference](docs/functions.md) ·
[Runnable demos](demo/) ·
[AI-assisted migration](docs/ai-assisted-migration.md)

```sql
INSTALL duck_diff FROM community;   -- one time, on stock DuckDB
LOAD duck_diff;
```

Signed per-platform release binaries and source builds:
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) ·
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## 1 · Spot the odd duck — diff two tables in one line

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

Take `SELECT *` for every column expanded, or project just the slice your use
case needs. Two companions round it out:
`schema_diff(left, right)` compares column names and types without reading a
row, and `table_diff_summary(…)` returns one row of counts and percentages —
in sync means everything lands in `n_identical`:

```sql
SELECT n_total = n_identical AS in_sync
FROM table_diff_summary('FROM users_v1', 'FROM users_v2', pk := 'id');   -- false
```

## 2 · Get your ducks in a row — verify CDC pipes, replicas, migrations

Each relation argument is a query string, so each side can point anywhere.
Use dollar-quoting for nested quotes, and the native pass-through functions
(`postgres_query`, `mysql_query`, `mssql_scan`, `bigquery_query`,
`snowflake_query`) so the remote system runs your SQL *in its own dialect*
and ships back only the rows you asked for:

```sql
SELECT * FROM table_diff(
  $$ FROM postgres_query('pg', 'SELECT id, email, plan FROM public.customers') $$,
  -- clickhouse_query is a three-line macro over ClickHouse's HTTP interface — see demo/
  $$ FROM clickhouse_query('SELECT id, email, plan FROM appdb.customers FINAL
                            WHERE _peerdb_is_deleted = 0') $$,
  pk := 'id',
  require_matching_columns := false,
  upcast_types := true,              -- reconcile the two type systems
  timestamp_precision := 'second'    -- drop precision lost in transit
);
```

Per key, this catches what row counts can't: **CDC validation**
(ClickPipes/PeerDB, Debezium, Fivetran — stale rows, missed deletes,
not-yet-synced inserts), **replica integrity** (`pt-table-checksum`, but
row-by-row), **migration/ELT parity** (did every row land intact?), and
**snapshot drift** between points in time.

Ready-to-run recipes live in [demo/](demo/) — MySQL ↔ read replica,
MySQL ↔ BigQuery, Postgres ↔ Snowflake, ClickHouse ↔ Parquet on S3,
Iceberg ↔ DuckLake, Postgres ↔ Amazon S3 Tables, and the Postgres ↔ ClickHouse
CDC audit — with credentials via env vars, a docker-compose playground seeded
with intentional drift, interactive HTML reports, and one-file `uv` Python
scripts (`diff_report.py`, `mysql_bigquery_etl.py`). Or point-and-click a
recipe for your pair on the
[website](https://avaitla.github.io/duck_diff/).

## 3 · Same query, new pond — transpile SQL between dialects with Claude

LLMs translate SQL between dialects well and can't tell when they got it
right — the diff can. Freeze a golden snapshot, convert one section at a
time, accept only when the diff comes back 100% identical, and feed the
drifted rows back on failure. The full workflow, a copy-paste prompt, and
ready-made `/goal` phrasings:
[docs/ai-assisted-migration.md](docs/ai-assisted-migration.md).

It ships as Claude Code **skills** in [.claude/skills/](.claude/skills/) —
`sql-migrate` (dialect conversion), `etl-check` (sync audits), and
`sql-optimize` (below) — auto-loaded in any Claude Code session opened in
this repo; copy a folder to `~/.claude/skills/` to use it everywhere.

## 4 · Fly faster, land the same — optimize a query without changing its answer

The same gate turns performance tuning into a safe search: rewrite → time it
→ diff it → **keep the rewrite only if it's faster AND the diff says
identical** → repeat.

```sql
SELECT n_total = n_identical AS accepted
FROM table_diff_summary('FROM golden', 'FROM candidate', pk := ['origin', 'rnk']);
```

On a public 231k-row dataset, a quadratic self-join rewritten as a window
function went **17.0 s → 0.01 s (~1700×)** with the diff proving all 177
result rows byte-identical — the worked example is on the
[website](https://avaitla.github.io/duck_diff/#sect4), and the `sql-optimize`
skill runs the loop autonomously.

The acceptance queries you finish with double as **regression tests in CI**:
[examples/](examples/) shows the sqllogictest pattern, runnable with nothing
but the `duckdb` CLI.

## Functions

| Function | Returns | Purpose |
|----------|---------|---------|
| `table_diff(left, right, pk := …)` | table | one row per key: key column(s), `diff_status`, `diff_data`, expanded per-column values |
| `table_diff_summary(left, right, pk := …)` | one row | counts (and percentages) per status |
| `schema_diff(left, right)` | table | per-column name/type comparison: `column_name`, `left_type`, `right_type`, `status` |

Comparison is NULL-safe: `NULL` equals `NULL`. The full reference — every
parameter (`columns`, `ignore`, `context`, `prefix`, the tolerance flags,
cross-type comparison), output shapes, recipes, and performance/caching
notes — is in [docs/functions.md](docs/functions.md).

## Development

```sh
git clone --recurse-submodules https://github.com/avaitla/duck_diff
cd duck_diff
GEN=ninja make                             # builds a duckdb shell with duck_diff loaded
build/release/test/unittest "test/sql/*"   # run the SQL test suite
```

Details (loadable binary, prerequisites, using a local build):
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Cutting a release:
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md), with notes accumulated in
[RELEASE_NOTES.md](RELEASE_NOTES.md).

## License

[MIT](LICENSE). Bundles DuckDB, which is also MIT-licensed.
