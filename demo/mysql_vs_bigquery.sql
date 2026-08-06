-- Migration parity: an orders table replicated from MySQL into BigQuery —
-- did every row arrive, and did any values change in flight?
--
-- Env vars used: MYSQL_HOST, MYSQL_PORT, MYSQL_DATABASE,
-- MYSQL_USER, MYSQL_PASSWORD, BQ_PROJECT. BigQuery authenticates through
-- Application Default Credentials (GOOGLE_APPLICATION_CREDENTIALS pointing at
-- a service-account key, or `gcloud auth application-default login`) — no
-- credential appears in this file.

INSTALL mysql;
LOAD mysql;
INSTALL bigquery FROM community;
LOAD bigquery;

CREATE SECRET mysql_src (
    TYPE mysql,
    HOST     getenv('MYSQL_HOST'),
    PORT     getenv('MYSQL_PORT')::INTEGER,
    DATABASE getenv('MYSQL_DATABASE'),
    USER     getenv('MYSQL_USER'),
    PASSWORD getenv('MYSQL_PASSWORD')
);
ATTACH '' AS src (TYPE mysql, SECRET mysql_src, READ_ONLY);

-- The BigQuery project id comes from the environment too: table-function
-- arguments are constant expressions, so getenv() works inline.
SELECT * FROM table_diff_summary(
    $$ SELECT id, customer_id, status, total_cents, created_at
       FROM src.orders $$,
    $$ FROM bigquery_query(getenv('BQ_PROJECT'), '
           SELECT id, customer_id, status, total_cents, created_at
           FROM analytics.orders') $$,
    pk := 'id',
    -- MySQL INT vs BigQuery INT64, VARCHAR vs STRING, …: reconcile the two
    -- type systems on their common super-type instead of erroring.
    require_matching_columns := false,
    upcast_types := true
);

-- The rows that didn't survive the pipeline intact, and what changed:
SELECT id, diff_status, diff_data
FROM table_diff(
    $$ SELECT id, customer_id, status, total_cents, created_at
       FROM src.orders $$,
    $$ FROM bigquery_query(getenv('BQ_PROJECT'), '
           SELECT id, customer_id, status, total_cents, created_at
           FROM analytics.orders') $$,
    pk := 'id',
    require_matching_columns := false,
    upcast_types := true,
    timestamp_precision := 'second'   -- tolerate sub-second loss in the pipeline
)
WHERE diff_status <> 'identical'
ORDER BY id;
