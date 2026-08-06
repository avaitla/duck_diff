# Release notes

Notes for the next release are accumulated here under **Unreleased**; cutting a
release (see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)) uses this file via
`gh release create … --notes-file RELEASE_NOTES.md`, after which the section is
retitled to the released version.

## Unreleased

### Cross-database diff demos ([demo/](demo/))

A suite of ready-to-run recipes that point `table_diff` / `table_diff_summary`
at data living in different systems, with every credential supplied through
environment variables (`CREATE SECRET … getenv()`) — nothing inlined in the
SQL:

- **MySQL primary ↔ read replica** — is the replica in sync?
  (`pt-table-checksum`, but row-by-row)
- **MySQL ↔ BigQuery** — did the migration/ELT copy land intact?
- **Postgres ↔ Snowflake** — does the rewritten warehouse model produce the
  original numbers?
- **ClickHouse ↔ Parquet on S3** — does the bulk-loaded table match the source
  files?
- **Iceberg ↔ DuckLake** — lakehouse migration parity check (Postgres catalog,
  S3 data)
- **Postgres ↔ Amazon S3 Tables** — is the CDC/ETL analytics copy faithful?
- **Postgres ↔ ClickHouse** — **CDC validation**: audit a ClickPipes (PeerDB)
  pipe, `FINAL` + `_peerdb_is_deleted` aware, catching stale rows, missed
  deletes, and not-yet-synced inserts.

Also included:

- **Local docker-compose playground** — empty vanilla Postgres, ClickHouse,
  and two MySQL containers, seeded entirely through DuckDB extensions with
  intentional drift, so three of the demos (replica drift, the ClickPipes CDC
  audit, bulk-load verification) run end-to-end with no cloud accounts.
- **HTML diff reports** — `report.sh` renders any demo as a standalone,
  interactive web page (sortable columns, search, `diff_status` filter chips,
  `diff_data` unrolled into per-column `old → new` lines), and
  `html_report.sql` provides the same as a plain SQL macro usable from any
  DuckDB client.

### One-file Python scripts (uv)

- `demo/diff_report.py` — run any diff and open an interactive report web
  page (JSON-embedded, windowed rendering — built for large diffs);
  `uv run diff_report.py …`, no venv or pip install.
- `demo/mysql_bigquery_etl.py` — diff-driven ETL example: bootstrap a MySQL
  table into BigQuery, then converge by repairing only the drifted keys,
  with a `table_diff_summary` verification pass. Idempotent.

### Docs & site

- **GitHub Pages site** (`site/`) — an interactive recipe builder: pick a
  source and destination (Postgres, MySQL, SQL Server, MongoDB, ClickHouse,
  BigQuery, Snowflake, Iceberg, Delta, DuckLake, S3 Tables, Parquet/CSV/JSON,
  Azure, GCS, Google Sheets, …) and copy generated SQL with schema diff +
  data diff, env-var credentials, and linked core/community extensions.
- [docs/ai-assisted-migration.md](docs/ai-assisted-migration.md) — using
  Claude to convert SQL between dialects with `table_diff` as the acceptance
  loop, one section at a time; includes a copy-paste prompt.
- **Claude Code skills** — `.claude/skills/sql-migrate` (dialect conversion
  with the diff as the agent's acceptance test), `.claude/skills/sql-optimize`
  (iterative performance tuning gated on an identical diff), and
  `.claude/skills/etl-check` (is this replica/CDC/warehouse copy in sync —
  lag-aware, evidence-first). The diff makes these loops safe to run
  autonomously: Claude validates its own correctness at every step.
  Auto-loaded in sessions opened in this repo; copy to `~/.claude/skills/`
  to use everywhere.

### Housekeeping

- Upgraded the bundled DuckDB to v1.5.5.
- `duck_diff` is now installable from the DuckDB community extension
  repository: `INSTALL duck_diff FROM community;`
