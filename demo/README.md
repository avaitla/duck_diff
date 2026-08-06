# Cross-database diff demos

Ready-to-run recipes that point `table_diff` / `table_diff_summary` at data
living in **different systems** — an operational database on one side, a
warehouse, lakehouse, or object store on the other. Each `.sql` file is one
scenario; together they cover MySQL, Postgres, BigQuery, Snowflake,
ClickHouse, Parquet on S3, Iceberg, DuckLake, and Amazon S3 Tables.

| File | Compares | Scenario |
|------|----------|----------|
| [`mysql_primary_vs_replica.sql`](mysql_primary_vs_replica.sql) | MySQL ↔ MySQL | Is the RDS read replica in sync with its primary? (`pt-table-checksum`, but row-by-row) |
| [`mysql_vs_bigquery.sql`](mysql_vs_bigquery.sql) | MySQL ↔ BigQuery | Did the migration/ELT copy land intact? |
| [`postgres_vs_snowflake.sql`](postgres_vs_snowflake.sql) | Postgres ↔ Snowflake | Does the rewritten warehouse model produce the original numbers? |
| [`clickhouse_vs_s3_parquet.sql`](clickhouse_vs_s3_parquet.sql) | ClickHouse ↔ Parquet on S3 | Does the bulk-loaded table match the source files? |
| [`iceberg_vs_ducklake.sql`](iceberg_vs_ducklake.sql) | Iceberg ↔ DuckLake (Postgres catalog, S3 data) | Lakehouse migration parity check |
| [`postgres_vs_s3tables.sql`](postgres_vs_s3tables.sql) | Postgres ↔ Amazon S3 Tables | Is the CDC/ETL analytics copy faithful? |
| [`postgres_vs_clickhouse.sql`](postgres_vs_clickhouse.sql) | Postgres ↔ ClickHouse | Audit a ClickPipes (PeerDB) CDC pipe, `FINAL` + `_peerdb_is_deleted` aware |

The table and column names in the demos are examples — point them at your own
schemas. Everything else (connectivity, secrets, the diff itself) is real and
runnable as-is.

## Run

Export the variables the demo needs (each file's header lists them; full
catalog below), then run it:

```sh
export PGHOST=prod-db.internal PGPORT=5432 PGDATABASE=appdb PGUSER=readonly
export PGPASSWORD=…
./run.sh postgres_vs_snowflake.sql
```

- Credentials come from the process environment — nothing is inlined in the
  SQL. Any secret-manager wrapper that injects env vars works as-is:
  `op run -- ./run.sh …`, `doppler run -- ./run.sh …`,
  `aws-vault exec prod -- ./run.sh …`, or
  `export PGPASSWORD="$(vault kv get -field=password secret/pg)"`.
- Optional: keep the exports in a `.env` file here instead
  (`cp .env.example .env`) — it is gitignored and sourced automatically by
  `run.sh` and `report.sh` when present; its values win over
  already-exported variables.
- `run.sh` prepends a `LOAD` of duck_diff and pipes the demo through
  `duckdb -unsigned` (release binaries of duck_diff are third-party
  signed — see [docs/DISTRIBUTION.md](../docs/DISTRIBUTION.md)).
- Overrides: `DUCKDB=/path/to/duckdb` and
  `DUCK_DIFF=/path/to/duck_diff.duckdb_extension` (defaults to the installed
  extension name `duck_diff`).
- Each demo `INSTALL`s the connector extensions it needs (`mysql`,
  `postgres`, `iceberg`, `ducklake`, `httpfs`, `aws`, plus `bigquery` and
  `snowflake` from the
  [community repository](https://duckdb.org/community_extensions/)) — the
  first run downloads them. ClickHouse needs no extension at all: the demos
  define a three-line `clickhouse_query()` macro that reads Parquet straight
  off its HTTP interface with `read_parquet()`.

## Environment variables

| Demo | Variables |
|------|-----------|
| `mysql_primary_vs_replica` | `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_REPLICA_HOST`, `MYSQL_REPLICA_PORT`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD` |
| `mysql_vs_bigquery` | `MYSQL_*` (primary only) and `BQ_PROJECT`, plus BigQuery ADC: `GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json` or `gcloud auth application-default login` |
| `postgres_vs_snowflake` | `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_WAREHOUSE` |
| `clickhouse_vs_s3_parquet` | `CLICKHOUSE_URL`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKS_S3_GLOB`, plus the AWS chain |
| `iceberg_vs_ducklake` | `ICEBERG_ORDERS_PATH`, `DUCKLAKE_DATA_PATH`, `DUCKLAKE_PG_HOST`, `DUCKLAKE_PG_PORT`, `DUCKLAKE_PG_DATABASE`, `DUCKLAKE_PG_USER`, `DUCKLAKE_PG_PASSWORD`, plus the AWS chain |
| `postgres_vs_s3tables` | `PG*` (above), plus the AWS chain; the table-bucket ARN is edited in the file |
| `postgres_vs_clickhouse` | `PG*` and `CLICKHOUSE_*` (above) |

"The AWS chain" means whatever the standard AWS credential chain finds:
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION` env vars, an
`AWS_PROFILE` (config/SSO), or an attached IAM role — resolved by
`CREATE SECRET (TYPE s3, PROVIDER credential_chain)`. For ClickHouse Cloud,
`CLICKHOUSE_URL=https://<instance>.clickhouse.cloud:8443`.

## Local playground (docker compose)

Three demos run end-to-end against open-source services on your machine — no
cloud accounts. [`docker-compose.yml`](docker-compose.yml) starts **empty,
vanilla** containers (Postgres, ClickHouse, and two MySQLs — a "primary" and
a "replica"), each requiring real username/password auth so the env-var
secret flow is exercised for real. All schemas and data are then loaded by
[`docker/seed.sql`](docker/seed.sql) **through DuckDB extensions alone** —
no init scripts inside the containers:

```sh
cd demo
docker compose up -d --wait              # empty postgres + clickhouse + 2× mysql
cp local.env .env                        # localhost ports + throwaway dev credentials
./run.sh docker/seed.sql                 # DuckDB loads all four databases + the parquet file

./run.sh mysql_primary_vs_replica.sql    # MySQL primary vs drifted replica
./run.sh postgres_vs_clickhouse.sql      # ClickPipes-style CDC audit
./run.sh clickhouse_vs_s3_parquet.sql    # bulk-load verification vs the parquet file
./report.sh postgres_vs_clickhouse.sql   # same, as an interactive HTML page

docker compose down -v                   # tear it all down
```

How the seed writes each system: the MySQLs and Postgres through their
read-write DuckDB extensions (`DROP TABLE` / `CREATE TABLE … AS`); ClickHouse
exactly like the **ClickHouse Cloud HTTP client** — the SQL is POSTed to the
HTTP(S) endpoint with `X-ClickHouse-User`/`X-ClickHouse-Key` header auth (via
the community `http_client` extension), so pointing `CLICKHOUSE_URL` at
`https://<instance>.clickhouse.cloud:8443` runs the same statements against
Cloud; and the parquet file with a plain `COPY … TO`.

The seed contains intentional drift so every `diff_status` appears: the
replica has a changed, a missing, and an extra order; the ClickHouse
`customers` table mimics a ClickPipes destination (ReplacingMergeTree with
`_peerdb_*` columns, a stale row, a not-yet-synced insert and delete, a
correctly synced delete, and a double row version that `FINAL` collapses);
and `events.clicks` was "loaded badly" from the parquet file (one
fat-fingered amount, one lost row, one spurious row). Expected results are
spelled out inline in `docker/seed.sql`. `local.env` is committed on
purpose — everything in it is a throwaway credential for these containers.
Host ports are offset (15432, 13306, 13307, 18123) to avoid colliding with
anything already running.

## One-file Python scripts (uv)

Two standalone scripts carry inline dependency metadata (PEP 723), so
`uv run <script>` provisions Python + the `duckdb` package on the fly — no
venv, no pip install:

- [`diff_report.py`](diff_report.py) — run any diff and open an
  **interactive report web page**. Unlike `report.sh` (which emits every row
  as HTML), it embeds the diff as JSON and renders client-side with windowed
  rows, so search/sort/filter stay snappy on diffs far too large for a plain
  DOM table:

  ```sh
  uv run diff_report.py \
      --left "FROM read_csv('a.csv')" --right "FROM read_csv('b.csv')" \
      --pk id --upcast --serve
  ```

  Point `--setup` at a SQL file with your ATTACH/secret preamble;
  `getenv('X')` calls in it are rewritten from the process environment
  (`getenv()` itself is CLI-only). `DUCK_DIFF=/path/to/ext` loads a local
  build instead of the community extension.

- [`mysql_bigquery_etl.py`](mysql_bigquery_etl.py) — **diff-driven ETL**:
  bootstrap a MySQL table into BigQuery if it's missing, otherwise let
  `table_diff` find the drift and repair *only* that (INSERT `left_only`,
  DELETE+re-INSERT `different`, DELETE `right_only`), then verify with
  `table_diff_summary`. Idempotent — rerun until converged:

  ```sh
  export MYSQL_HOST=… MYSQL_PORT=3306 MYSQL_DATABASE=appdb \
         MYSQL_USER=… MYSQL_PASSWORD=… BQ_PROJECT=my-project
  uv run mysql_bigquery_etl.py --table orders --dataset analytics --pk id --dry-run
  uv run mysql_bigquery_etl.py --table orders --dataset analytics --pk id
  ```

## Viewing a diff as a web page

[`report.sh`](report.sh) renders any demo to a standalone, **interactive**
HTML page — same env vars (and optional `.env`) as `run.sh`, one table per
query, with click-to-sort headers, a per-table search box, clickable
`diff_status` filter chips, and a live row count. `diff_data` JSON is
unrolled into per-column `old → new` lines (any other JSON cell gets a
collapsible pretty-printed view). Everything is inlined, so the file needs
no network access and can be attached to a ticket or shared:

```sh
./report.sh postgres_vs_clickhouse.sql   # writes postgres_vs_clickhouse.html
```

The script opens the page in your default browser when it finishes (`open`
on macOS, `xdg-open` on Linux). Afterwards it is a plain static file —
reopen it anytime with `open postgres_vs_clickhouse.html` (or double-click
it), and `python3 -m http.server` in this directory gives it a shareable URL
on your network.

### From inside the duckdb shell

No wrapper script needed: [`html_report.sql`](html_report.sql) defines a
`html_report(sql)` table macro that renders **any** query's result as the
same interactive page (it serializes each row generically via `to_json`, so
it works for every `table_diff` shape). Trigger it with a `COPY … TO` and
open the file with `.shell`:

```sql
-- inside `duckdb -unsigned`
LOAD duck_diff;
.read html_report.sql
COPY (FROM html_report($$
    SELECT * FROM table_diff('FROM primary_db.orders', 'FROM replica_db.orders', pk := 'id')
$$)) TO 'diff.html' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
.shell open diff.html
```

The `QUOTE '' , ESCAPE ''` options make `COPY` write the macro's single
VARCHAR cell verbatim, so `diff.html` is a normal standalone web page.
`.shell` runs a host command from the shell — use `xdg-open` on Linux.
(`.read`/`.shell` are CLI conveniences; the `CREATE MACRO` + `COPY`
statements are plain SQL and work from any DuckDB client. The CLI's raw
`.mode html` + `.once out.html` also exists, but it emits an unstyled table
fragment rather than a full page.)

For *interactive* exploration, materialize the diff into a database file and
open DuckDB's built-in browser UI on it:

```sh
duckdb -unsigned diff.db -c "LOAD duck_diff;
  CREATE TABLE drift AS FROM table_diff('FROM …', 'FROM …', pk := 'id');"
duckdb -ui diff.db     # serves http://localhost:4213 and opens your browser
```

(To let *other* machines query the results over HTTP, there is also the
community [`httpserver`](https://duckdb.org/community_extensions/extensions/httpserver)
extension.)

## How secrets stay out of the SQL

No demo contains a credential literal. Three mechanisms carry them from the
environment instead:

1. **`CREATE SECRET … getenv('VAR')`** — secret values are constant
   expressions, so the CLI's `getenv()` reads them straight from the
   environment into DuckDB's Secrets Manager (which redacts them in
   `duckdb_secrets()` output). Used for MySQL, Postgres, Snowflake, DuckLake,
   and the ClickHouse HTTP auth headers.

2. **Provider credential chains** — some connectors already know how to find
   credentials in the environment, so the SQL says nothing at all:
   - BigQuery uses *Application Default Credentials*
     (`GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json`, or
     `gcloud auth application-default login`).
   - S3 access uses `CREATE SECRET (TYPE s3, PROVIDER credential_chain)` —
     the standard AWS chain: env vars, `~/.aws` profile/SSO, or an IAM role.

3. **`getenv()` in table-function arguments** — table-function arguments are
   also constant expressions, so paths and endpoints come from the
   environment too: `read_parquet(getenv('CLICKS_S3_GLOB'))`,
   `iceberg_scan(getenv('ICEBERG_ORDERS_PATH'))`,
   `bigquery_query(getenv('BQ_PROJECT'), …)`,
   `ch_scan(…, getenv('CLICKHOUSE_URL'))`.

The one thing that *cannot* come from the environment is an `ATTACH` path
(the parser requires a literal string). The demos only ever put non-secret
configuration there — an empty string deferring to a secret, the
`ducklake:secret_name` shorthand, or the S3 Tables bucket ARN.

> **Note:** `getenv()` is a feature of the `duckdb` CLI. From a host language
> (Python, Node, …), read the environment there (e.g. `os.environ`) when
> constructing the `CREATE SECRET` statement — same principle: credentials
> live in the environment, never in checked-in SQL.

## Connector references

- [MySQL extension](https://duckdb.org/docs/stable/core_extensions/mysql) ·
  [Postgres extension](https://duckdb.org/docs/stable/core_extensions/postgres) ·
  [Iceberg extension](https://duckdb.org/docs/stable/core_extensions/iceberg/overview) ·
  [DuckLake](https://ducklake.select/docs/)
- Community: [`bigquery`](https://github.com/hafenkran/duckdb-bigquery) ·
  [`snowflake`](https://github.com/iqea-ai/duckdb-snowflake)
- ClickHouse: no extension — the demos read Parquet from its
  [HTTP interface](https://clickhouse.com/docs/en/interfaces/http) via
  `read_parquet()` + an `http` secret for the auth headers
