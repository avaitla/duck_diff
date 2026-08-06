---
name: etl-check
description: Check whether two databases/tables are in sync using duck_diff — replication lag, CDC pipelines (ClickPipes/Debezium/Fivetran), ETL copies, migration parity. Use when asked whether a replica, warehouse copy, or synced table matches its source, or to audit/validate a data pipeline's output.
---

# ETL / replication sync check with duck_diff

You are verifying that a destination table faithfully mirrors a source table.
The verdict comes from `table_diff`, not sampling or row counts: every key is
classified `identical` / `different` / `left_only` / `right_only`.

## 1 — Establish the two sides

- Ask (or infer from the repo/env) the source and destination systems, the
  table(s), and the primary key. Never accept "the row counts match" as the
  check — counts hide 1:1 swaps.
- Connect DuckDB to both sides. Use the env-var patterns from this repo's
  demo/ directory (CREATE SECRET … getenv, ATTACH … READ_ONLY); do not inline
  credentials into SQL or shell history. Core extensions cover
  postgres/mysql/sqlite/iceberg/delta/ducklake; community covers
  bigquery/snowflake/mssql/mongo; ClickHouse needs only the httpfs +
  read_parquet macro (see demo/postgres_vs_clickhouse.sql).
- `INSTALL duck_diff FROM community; LOAD duck_diff;`
- CDC destinations need their read shaped first: ClickPipes/PeerDB lands
  ReplacingMergeTree — read with `FINAL` and `WHERE _peerdb_is_deleted = 0`;
  other CDC tools have equivalent soft-delete/version columns.

## 2 — Run the check, cheapest signal first

1. **Schema**: `FROM schema_diff($$ <src> $$, $$ <dst> $$) WHERE status <> 'identical';`
   Columns on only one side (pipeline bookkeeping like `_synced_at`) go into
   `ignore := […]`; `type_differs` is normal cross-engine → use
   `require_matching_columns := false, upcast_types := true`.
2. **Summary**: `FROM table_diff_summary($$ <src> $$, $$ <dst> $$, pk := …, <options>);`
   In sync ⇔ everything is `n_identical`. For expensive/remote sides,
   materialize each side into a local table first and diff the copies.
3. **Drill-down** only if the summary is dirty:
   - by column: `SELECT unnest(json_keys(diff_data)) col, count(*) FROM table_diff(…) WHERE diff_status='different' GROUP BY col ORDER BY 2 DESC;`
   - sample rows: `FROM table_diff(…) WHERE diff_status <> 'identical' LIMIT 20;`
     Include `updated_at`-style columns in the output — they separate lag
     from corruption.

## 3 — Separate lag from real drift

Live pipelines always have an in-flight tail. Before declaring a pipeline
broken:

- Restrict both sides to settled rows:
  `WHERE updated_at < now() - INTERVAL 5 MINUTE` (both sides, same clock —
  `SET TimeZone = 'UTC';`).
- Re-run the summary. Drift that survives the settling window is real:
  `different` = corrupted/stale values, `left_only` = missed inserts or
  missed deletes downstream, `right_only` = missed deletes upstream or
  spurious writes.
- Cross-engine value noise (float rounding, sub-second timestamps, '' vs
  NULL) is a tolerance decision for the user — propose the smallest of
  `numeric_tolerance` / `timestamp_precision` / `null_equals_empty` with
  sample rows as evidence; don't apply silently.

## 4 — Report

- Verdict per table: IN SYNC or N drifted keys broken down by status, with
  the settled-window caveat stated.
- Evidence: the summary row, the changed-column histogram, and ≤20 sample
  drifted rows. For a shareable artifact, render with demo/report.sh or
  `uv run demo/diff_report.py … --serve` (interactive HTML).
- If asked to fix rather than just check: repair only the drifted keys
  (INSERT `left_only`, DELETE+re-INSERT `different`, DELETE `right_only`) —
  demo/mysql_bigquery_etl.py is the reference implementation — then re-run
  the summary to prove convergence.
- Checking many tables: loop table names, run the summary for each, and
  present one table of verdicts before any drill-down.
