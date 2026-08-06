#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["duckdb>=1.1"]
# ///
"""Diff-driven ETL: bootstrap, then converge, a MySQL table into BigQuery.

Instead of re-copying the whole table on every run (slow) or trusting the
pipeline blindly (risky), let the diff drive the sync:

  bootstrap   destination table missing            -> copy it wholesale
  converge    destination exists                   -> table_diff() finds the
              drift, and only those rows are repaired:
                left_only   (in MySQL, not BigQuery)  -> INSERT
                different   (values drifted)          -> DELETE + re-INSERT
                right_only  (gone from MySQL)         -> DELETE
  verify      re-run table_diff_summary(); converged means 100% n_identical

Runs are idempotent — re-run until clean. A schema_diff() check runs first
and refuses to converge over column/type mismatches.

Env vars: MYSQL_HOST, MYSQL_PORT, MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD,
BQ_PROJECT — plus BigQuery Application Default Credentials
(GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json, or
`gcloud auth application-default login`).

Usage:
    uv run mysql_bigquery_etl.py --table orders --dataset analytics --pk id
    uv run mysql_bigquery_etl.py --table orders --dataset analytics --pk id --dry-run
"""

from __future__ import annotations

import argparse
import os
import sys

import duckdb

CHUNK = 500  # keys per DELETE/INSERT statement


def sql_str(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"required env var {name} is not set")
    return value


def key_literal(value) -> str:
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return str(value)
    return sql_str(str(value))


def chunks(seq, n=CHUNK):
    for i in range(0, len(seq), n):
        yield seq[i : i + n]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--table", default="orders", help="MySQL table (and BigQuery table name)")
    ap.add_argument("--dataset", default="analytics", help="BigQuery dataset")
    ap.add_argument("--pk", default="id", help="primary key column (single column)")
    ap.add_argument("--timestamp-precision", default="second",
                    help="tolerate timestamp precision lost in transit (default: second)")
    ap.add_argument("--dry-run", action="store_true", help="report the drift, change nothing")
    args = ap.parse_args()
    if "," in args.pk:
        sys.exit("this example keeps the repair statements simple with a single-column pk")

    table, dataset, pk = args.table, args.dataset, args.pk
    src = f"src.{table}"
    dst = f"bq.{dataset}.{table}"

    con = duckdb.connect()
    con.execute("INSTALL duck_diff FROM community; LOAD duck_diff;")
    con.execute("INSTALL mysql; LOAD mysql;")
    con.execute("INSTALL bigquery FROM community; LOAD bigquery;")

    # Credentials come from the environment; the secret manager redacts them.
    con.execute(f"""
        CREATE SECRET mysql_src (
            TYPE mysql,
            HOST     {sql_str(env('MYSQL_HOST'))},
            PORT     {int(env('MYSQL_PORT'))},
            DATABASE {sql_str(env('MYSQL_DATABASE'))},
            USER     {sql_str(env('MYSQL_USER'))},
            PASSWORD {sql_str(env('MYSQL_PASSWORD'))}
        )""")
    con.execute("ATTACH '' AS src (TYPE mysql, SECRET mysql_src, READ_ONLY)")
    con.execute(f"ATTACH 'project={env('BQ_PROJECT')}' AS bq (TYPE bigquery)")

    # MySQL INT vs BigQuery INT64, VARCHAR vs STRING, …: reconcile the two
    # type systems on their common super-type; truncate timestamps to absorb
    # sub-second precision lost in the pipeline.
    diff_opts = (
        f"pk := {sql_str(pk)}, "
        "require_matching_columns := false, upcast_types := true, "
        f"timestamp_precision := {sql_str(args.timestamp_precision)}"
    )

    # ---- bootstrap ---------------------------------------------------------
    try:
        con.execute(f"SELECT 1 FROM {dst} LIMIT 0")
    except duckdb.Error:
        print(f"{dst} does not exist -> bootstrap: full copy from {src}")
        if args.dry_run:
            return
        con.execute(f"CREATE TABLE {dst} AS FROM {src}")
        verify(con, src, dst, diff_opts)
        return

    # ---- schema check: never converge over a shape mismatch ---------------
    mismatches = con.execute(
        f"FROM schema_diff($$ FROM {src} $$, $$ FROM {dst} $$) "
        "WHERE status NOT IN ('identical', 'type_differs')"  # upcast handles type drift
    ).fetchall()
    if mismatches:
        for row in mismatches:
            print(f"schema mismatch: {row}")
        sys.exit("columns exist on only one side — fix the schema before converging")

    # ---- find the drift ----------------------------------------------------
    drift = con.execute(
        f"SELECT {pk}, diff_status FROM table_diff($$ FROM {src} $$, $$ FROM {dst} $$, {diff_opts}) "
        "WHERE diff_status <> 'identical'"
    ).fetchall()
    if not drift:
        print("already converged — nothing to do")
        return

    to_delete = [k for k, s in drift if s in ("different", "right_only")]
    to_insert = [k for k, s in drift if s in ("different", "left_only")]
    by_status = {s: sum(1 for _, x in drift if x == s) for s in ("different", "left_only", "right_only")}
    print(f"drift: {by_status}  ->  DELETE {len(to_delete)} keys, INSERT {len(to_insert)} keys")
    if args.dry_run:
        return

    # ---- repair: replace changed rows, add missing, drop stragglers --------
    for batch in chunks(to_delete):
        keys = ", ".join(key_literal(k) for k in batch)
        con.execute(f"DELETE FROM {dst} WHERE {pk} IN ({keys})")
    for batch in chunks(to_insert):
        keys = ", ".join(key_literal(k) for k in batch)
        # column order matches because the destination was bootstrapped from
        # this same source table
        con.execute(f"INSERT INTO {dst} SELECT * FROM {src} WHERE {pk} IN ({keys})")

    verify(con, src, dst, diff_opts)


def verify(con: duckdb.DuckDBPyConnection, src: str, dst: str, diff_opts: str) -> None:
    cur = con.execute(f"FROM table_diff_summary($$ FROM {src} $$, $$ FROM {dst} $$, {diff_opts})")
    cols = [d[0] for d in cur.description]
    row = dict(zip(cols, cur.fetchone()))
    print("verify:", row)
    if row["n_total"] and row["n_identical"] == row["n_total"]:
        print("converged: destination matches source")
    else:
        # Under live writes a small tail of in-flight rows is normal — rerun.
        sys.exit("not fully converged (source may have moved during the run) — rerun to catch up")


if __name__ == "__main__":
    main()
