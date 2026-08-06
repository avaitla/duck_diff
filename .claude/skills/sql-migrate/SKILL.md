---
name: sql-migrate
description: Convert SQL between dialects (Postgres, MySQL, BigQuery, Snowflake, ClickHouse, DuckDB, …) with duck_diff as the mechanical acceptance loop. Use when asked to migrate, port, translate, or rewrite SQL/views/dbt models to another database or dialect, or to verify a converted query produces identical results.
---

# SQL dialect migration with a duck_diff acceptance loop

You are converting SQL from one dialect to another. Correctness is decided by
`table_diff`, not by inspection: a section is DONE only when the diff between
the original's output and the converted query's output is 100% identical.

## Setup (once)

1. Get a DuckDB with duck_diff: `INSTALL duck_diff FROM community; LOAD duck_diff;`
   (or `LOAD` the locally built extension if this is the duck_diff repo).
2. Connect DuckDB to the source and/or target systems (postgres/mysql core
   extensions, bigquery/snowflake community extensions — see demo/ for
   env-var-based ATTACH patterns), or work from exported snapshots.
3. Extract and freeze the inputs, in a file-backed cache
   (`duckdb migration_cache.db`) so iterations are fast and stable:
   - List every source table the query reads (FROM / JOIN / CTE inputs).
   - Snapshot each one locally:
     `CREATE TABLE IF NOT EXISTS src_<t> AS FROM postgres_query('pg', 'SELECT * FROM <t>');`
   - Freeze the expected output — run the original query ON the source engine
     once: `CREATE TABLE IF NOT EXISTS golden_<section> AS <original section's output>;`
   - Do all conversion work against these frozen tables (a DuckDB target
     reads the `src_*` snapshots directly).
4. `SET TimeZone = 'UTC';` and parameterize nondeterministic inputs
   (`now()`, `random()`) on both sides before comparing.

## The loop — one section at a time

Split the query into sections (CTEs, subqueries, views, dbt models) and
convert them in dependency order. For each section:

1. Convert the section's SQL to the target dialect.
2. Shape check first: `FROM schema_diff('FROM golden_<s>', $$ <converted> $$)
   WHERE status <> 'identical';` — fix missing/renamed columns before looking
   at rows. (`type_differs` rows are usually handled by upcasting, below.)
3. Acceptance check:
   `SELECT n_total = n_identical AS accepted FROM table_diff_summary(
      'FROM golden_<s>', $$ <converted> $$, pk := '<key>',
      require_matching_columns := false, upcast_types := true);`
4. If not accepted, diagnose from the drift — never from re-reading the SQL
   alone:
   - changed-column histogram:
     `SELECT unnest(json_keys(diff_data)) col, count(*) FROM table_diff(…)
      WHERE diff_status = 'different' GROUP BY col ORDER BY 2 DESC;`
   - 20 concrete counterexamples:
     `FROM table_diff(…) WHERE diff_status <> 'identical' LIMIT 20;`
   Fix, re-run step 3.
5. Only when accepted: materialize the converted section's output as the
   input for downstream sections, record "section <s>: accepted, N rows",
   and move on.

Do not stop, summarize progress as if finished, or skip the acceptance query
for any section. Continue until every section passes.

## Tolerances need sign-off

If a diff failure is a genuine engine difference rather than a conversion
bug — float summation order, sub-second timestamp precision, `''` vs NULL —
do NOT silently add a tolerance. Show the user the exact drifted rows and
the smallest option that would accept them (`numeric_tolerance := <ε>`,
`timestamp_precision := 'second'`, `null_equals_empty := true`) and wait for
their decision. A tolerance is an accepted business difference, not a fix.

## Finish

- Keep the acceptance queries: turn them into a regression test (see
  examples/ in the duck_diff repo for the sqllogictest pattern) so future
  edits to the converted SQL are diffed against the goldens in CI.
- Report per-section row counts and any tolerances the user approved.
