-- ClickPipes audit: a Postgres table is CDC-replicated into ClickHouse Cloud
-- by ClickPipes (PeerDB). Is the ClickHouse copy faithful to the source?
--
-- ClickPipes lands tables as ReplacingMergeTree with _peerdb_* metadata
-- columns, so the ClickHouse side reads with FINAL (collapse row versions)
-- and filters out CDC-deleted rows before diffing.
--
-- Env vars used: PGHOST, PGPORT, PGDATABASE, PGUSER,
-- PGPASSWORD, CLICKHOUSE_URL, CLICKHOUSE_USER, CLICKHOUSE_PASSWORD.

INSTALL postgres;
LOAD postgres;
INSTALL httpfs;
LOAD httpfs;

-- Compare instants on a common clock: ClickHouse emits UTC-adjusted
-- timestamps (TIMESTAMPTZ) while the Postgres column is timezone-naive, and
-- naive values are interpreted in the session time zone during upcasting.
SET TimeZone = 'UTC';

CREATE SECRET pg_prod (
    TYPE postgres,
    HOST     getenv('PGHOST'),
    PORT     getenv('PGPORT')::INTEGER,
    DATABASE getenv('PGDATABASE'),
    USER     getenv('PGUSER'),
    PASSWORD getenv('PGPASSWORD')
);
ATTACH '' AS pg (TYPE postgres, SECRET pg_prod, READ_ONLY);

-- ClickHouse Cloud HTTP auth in request headers, scoped to the endpoint;
-- both values come from the environment.
CREATE SECRET clickhouse_auth (
    TYPE http,
    EXTRA_HTTP_HEADERS MAP {
        'X-ClickHouse-User': getenv('CLICKHOUSE_USER'),
        'X-ClickHouse-Key':  getenv('CLICKHOUSE_PASSWORD')
    },
    SCOPE getenv('CLICKHOUSE_URL')
);

-- No ClickHouse extension needed: its HTTP interface returns Parquet, which
-- read_parquet() consumes directly (auth via the http secret above).
CREATE MACRO clickhouse_query(q) AS TABLE
FROM read_parquet(concat(getenv('CLICKHOUSE_URL'),
                         '/?default_format=Parquet&query=', url_encode(q)));

-- Health check: all rows should be n_identical once the pipe has caught up.
SELECT * FROM table_diff_summary(
    $$ SELECT id, email, full_name, plan, updated_at
       FROM pg.public.customers $$,
    -- toDateTime64: ClickHouse writes plain DateTime to Parquet as UInt32
    -- epoch seconds, which cannot upcast against a Postgres TIMESTAMP.
    $$ FROM clickhouse_query('
           SELECT id, email, full_name, plan,
                  toDateTime64(updated_at, 0) AS updated_at
           FROM appdb.customers FINAL
           WHERE _peerdb_is_deleted = 0') $$,
    pk := 'id',
    -- Postgres timestamptz vs ClickHouse DateTime64, TEXT vs String, …
    require_matching_columns := false,
    upcast_types := true,
    timestamp_precision := 'second'
);

-- Drill down. Under live CDC a small tail of rows is always in flight;
-- left_only / different rows with a very recent updated_at are usually just
-- replication lag, so surface the timestamps alongside the verdict.
SELECT id, diff_status, diff_data, updated_at_left, updated_at_right
FROM table_diff(
    $$ SELECT id, email, full_name, plan, updated_at
       FROM pg.public.customers $$,
    -- toDateTime64: ClickHouse writes plain DateTime to Parquet as UInt32
    -- epoch seconds, which cannot upcast against a Postgres TIMESTAMP.
    $$ FROM clickhouse_query('
           SELECT id, email, full_name, plan,
                  toDateTime64(updated_at, 0) AS updated_at
           FROM appdb.customers FINAL
           WHERE _peerdb_is_deleted = 0') $$,
    pk := 'id',
    require_matching_columns := false,
    upcast_types := true,
    timestamp_precision := 'second'
)
WHERE diff_status <> 'identical'
ORDER BY id;
