-- Load verification: a ClickHouse events table was bulk-loaded from Parquet
-- files in S3 — confirm the table matches the files, row for row.
--
-- Env vars used: CLICKHOUSE_URL, CLICKHOUSE_USER,
-- CLICKHOUSE_PASSWORD, CLICKS_S3_GLOB, plus AWS credentials via the
-- standard chain.

INSTALL httpfs;
LOAD httpfs;
INSTALL aws;
LOAD aws;

-- ClickHouse HTTP-interface auth rides in request headers, scoped to just the
-- ClickHouse endpoint; both values come from the environment.
CREATE SECRET clickhouse_auth (
    TYPE http,
    EXTRA_HTTP_HEADERS MAP {
        'X-ClickHouse-User': getenv('CLICKHOUSE_USER'),
        'X-ClickHouse-Key':  getenv('CLICKHOUSE_PASSWORD')
    },
    SCOPE getenv('CLICKHOUSE_URL')
);

-- S3 credentials from the standard AWS chain: env vars, else your ~/.aws
-- config/SSO profile, else an instance/IAM role. Nothing inlined. Only
-- needed when CLICKS_S3_GLOB is an s3:// URL — on a machine with no AWS
-- setup at all (e.g. the local docker playground, where the glob is a local
-- path) this statement fails with a harmless validation error and the diff
-- below still runs.
CREATE SECRET aws_chain (TYPE s3, PROVIDER credential_chain);

-- No ClickHouse extension needed: its HTTP interface returns Parquet, which
-- read_parquet() consumes directly (auth via the http secret above).
CREATE MACRO clickhouse_query(q) AS TABLE
FROM read_parquet(concat(getenv('CLICKHOUSE_URL'),
                         '/?default_format=Parquet&query=', url_encode(q)));

SELECT * FROM table_diff_summary(
    $$ FROM clickhouse_query(
           'SELECT event_id, user_id, event_type, amount FROM events.clicks') $$,
    $$ SELECT event_id, user_id, event_type, amount
       FROM read_parquet(getenv('CLICKS_S3_GLOB')) $$,
    pk := 'event_id'
);

-- Any mismatches: the expanded per-column output shows both sides natively
-- typed, so you can filter and compute on them directly.
SELECT event_id, diff_status, amount_left, amount_right
FROM table_diff(
    $$ FROM clickhouse_query(
           'SELECT event_id, user_id, event_type, amount FROM events.clicks') $$,
    $$ SELECT event_id, user_id, event_type, amount
       FROM read_parquet(getenv('CLICKS_S3_GLOB')) $$,
    pk := 'event_id'
)
WHERE diff_status <> 'identical'
LIMIT 20;
