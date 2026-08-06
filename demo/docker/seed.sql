-- Seeds the whole docker-compose playground using nothing but DuckDB
-- extensions — no init scripts inside the containers:
--
--   * both MySQLs and Postgres are written through their read-write
--     DuckDB extensions (CREATE TABLE AS / DROP TABLE);
--   * ClickHouse is driven exactly like the ClickHouse Cloud HTTP client:
--     the SQL is POSTed to the HTTP(S) endpoint with header auth (the
--     `http_client` community extension supplies the POST) — point
--     CLICKHOUSE_URL at https://<instance>.clickhouse.cloud:8443 and the
--     same statements work against Cloud;
--   * the "source of truth" Parquet file is COPYed to disk.
--
-- Run from the demo/ directory (idempotent — safe to re-run):
--
--   cp local.env .env
--   ./run.sh docker/seed.sql
--
-- The drift between the systems is intentional, so every diff_status shows
-- up when the demos run. Expected outcomes are noted inline below.

INSTALL mysql;
LOAD mysql;
INSTALL postgres;
LOAD postgres;
INSTALL http_client FROM community;
LOAD http_client;

CREATE SECRET seed_mysql_primary (
    TYPE mysql,
    HOST     getenv('MYSQL_HOST'),
    PORT     getenv('MYSQL_PORT')::INTEGER,
    DATABASE getenv('MYSQL_DATABASE'),
    USER     getenv('MYSQL_USER'),
    PASSWORD getenv('MYSQL_PASSWORD')
);
CREATE SECRET seed_mysql_replica (
    TYPE mysql,
    HOST     getenv('MYSQL_REPLICA_HOST'),
    PORT     getenv('MYSQL_REPLICA_PORT')::INTEGER,
    DATABASE getenv('MYSQL_DATABASE'),
    USER     getenv('MYSQL_USER'),
    PASSWORD getenv('MYSQL_PASSWORD')
);
CREATE SECRET seed_pg (
    TYPE postgres,
    HOST     getenv('PGHOST'),
    PORT     getenv('PGPORT')::INTEGER,
    DATABASE getenv('PGDATABASE'),
    USER     getenv('PGUSER'),
    PASSWORD getenv('PGPASSWORD')
);

ATTACH '' AS primary_db (TYPE mysql, SECRET seed_mysql_primary);
ATTACH '' AS replica_db (TYPE mysql, SECRET seed_mysql_replica);
ATTACH '' AS pg         (TYPE postgres, SECRET seed_pg);

-- ClickHouse Cloud-style HTTP client: POST the statement to the endpoint
-- with header auth — the same shape as
--   curl -X POST 'https://<instance>.clickhouse.cloud:8443/?query=…' \
--        -H 'X-ClickHouse-User: …' -H 'X-ClickHouse-Key: …'
-- POST is required for writes; the statement rides in the `query` URL
-- parameter and the body stays empty (ClickHouse treats a POST body as more
-- query text / INSERT data). Fails loudly (error()) on any non-2xx response.
CREATE MACRO clickhouse_execute(q) AS (
    WITH r AS (
        SELECT http_post_form(
                   getenv('CLICKHOUSE_URL') || '/?query=' || url_encode(q),
                   headers := MAP {
                       'X-ClickHouse-User': getenv('CLICKHOUSE_USER'),
                       'X-ClickHouse-Key':  getenv('CLICKHOUSE_PASSWORD')
                   },
                   params := MAP {}) AS resp
    )
    SELECT CASE WHEN resp.status::VARCHAR::INTEGER BETWEEN 200 AND 299 THEN 'OK'
                ELSE error('ClickHouse: ' || resp.body::VARCHAR)
           END
    FROM r
);

------------------------------------------------------------------------------
-- MySQL primary vs replica (mysql_primary_vs_replica.sql). Replica drift:
--   id 2 — status differs           -> different
--   id 4 — missing on the replica   -> left_only
--   id 6 — exists only there        -> right_only
------------------------------------------------------------------------------
DROP TABLE IF EXISTS primary_db.orders;
CREATE TABLE primary_db.orders AS
FROM (VALUES
    (1, 101, 'shipped',   4999, TIMESTAMP '2026-08-01 09:15:00'),
    (2, 102, 'shipped',   1250, TIMESTAMP '2026-08-02 14:40:00'),
    (3, 103, 'pending',   7800, TIMESTAMP '2026-08-04 11:05:00'),
    (4, 101, 'cancelled',  560, TIMESTAMP '2026-08-04 16:20:00'),
    (5, 104, 'shipped',   2115, TIMESTAMP '2026-08-05 08:55:00')
) t(id, customer_id, status, total_cents, created_at);

DROP TABLE IF EXISTS replica_db.orders;
CREATE TABLE replica_db.orders AS
FROM (VALUES
    (1, 101, 'shipped',   4999, TIMESTAMP '2026-08-01 09:15:00'),
    (2, 102, 'pending',   1250, TIMESTAMP '2026-08-02 14:40:00'),
    (3, 103, 'pending',   7800, TIMESTAMP '2026-08-04 11:05:00'),
    (5, 104, 'shipped',   2115, TIMESTAMP '2026-08-05 08:55:00'),
    (6, 105, 'shipped',   9990, TIMESTAMP '2026-08-05 09:30:00')
) t(id, customer_id, status, total_cents, created_at);

------------------------------------------------------------------------------
-- Postgres side of postgres_vs_clickhouse.sql. Drift vs ClickHouse:
--   id 1 — identical
--   id 2 — plan upgraded here, ClickHouse copy is stale        -> different
--   id 3 — new here, not yet replicated                        -> left_only
--   id 4 — deleted here, delete synced (_peerdb_is_deleted=1)  -> absent on both
--   id 5 — identical; ClickHouse holds two versions, FINAL collapses them
--   id 6 — deleted here, delete NOT yet synced                 -> right_only
------------------------------------------------------------------------------
DROP TABLE IF EXISTS pg.public.customers;
CREATE TABLE pg.public.customers AS
FROM (VALUES
    (1, 'ada@example.com',   'Ada Lovelace',   'pro',  TIMESTAMP '2026-08-01 10:00:00'),
    (2, 'linus@example.com', 'Linus Torvalds', 'pro',  TIMESTAMP '2026-08-03 09:30:00'),
    (3, 'grace@example.com', 'Grace Hopper',   'team', TIMESTAMP '2026-08-05 08:00:00'),
    (5, 'alan@example.com',  'Alan Turing',    'free', TIMESTAMP '2026-08-02 12:00:00')
) t(id, email, full_name, plan, updated_at);

------------------------------------------------------------------------------
-- ClickHouse, over its HTTP interface. appdb.customers mimics a ClickPipes
-- (PeerDB) CDC destination; events.clicks was "bulk-loaded badly" from the
-- parquet file:
--   event 3 — amount fat-fingered during the load  -> different
--   event 4 — exists only in ClickHouse            -> left_only
--   event 6 — in the parquet file, never loaded    -> right_only
------------------------------------------------------------------------------
SELECT clickhouse_execute('CREATE DATABASE IF NOT EXISTS appdb');
SELECT clickhouse_execute('DROP TABLE IF EXISTS appdb.customers');
SELECT clickhouse_execute('
    CREATE TABLE appdb.customers (
        id                 Int32,
        email              String,
        full_name          String,
        plan               String,
        updated_at         DateTime,
        _peerdb_synced_at  DateTime,
        _peerdb_is_deleted UInt8,
        _peerdb_version    UInt64
    ) ENGINE = ReplacingMergeTree(_peerdb_version) ORDER BY id');
SELECT clickhouse_execute($$
    INSERT INTO appdb.customers VALUES
    (1, 'ada@example.com',    'Ada Lovelace',    'pro',  '2026-08-01 10:00:00', '2026-08-01 10:00:05', 0, 1),
    (2, 'linus@example.com',  'Linus Torvalds',  'free', '2026-08-02 07:00:00', '2026-08-02 07:00:04', 0, 1),
    (4, 'edsger@example.com', 'Edsger Dijkstra', 'free', '2026-07-30 15:00:00', '2026-08-04 11:00:02', 1, 2),
    (5, 'alan@example.com',   'Alan T.',         'free', '2026-08-02 11:00:00', '2026-08-02 11:00:03', 0, 1),
    (5, 'alan@example.com',   'Alan Turing',     'free', '2026-08-02 12:00:00', '2026-08-02 12:00:04', 0, 2),
    (6, 'brian@example.com',  'Brian Kernighan', 'pro',  '2026-08-01 09:00:00', '2026-08-01 09:00:06', 0, 1)$$);

SELECT clickhouse_execute('CREATE DATABASE IF NOT EXISTS events');
SELECT clickhouse_execute('DROP TABLE IF EXISTS events.clicks');
SELECT clickhouse_execute('
    CREATE TABLE events.clicks (
        event_id   Int64,
        user_id    Int32,
        event_type String,
        amount     Float64
    ) ENGINE = MergeTree ORDER BY event_id');
SELECT clickhouse_execute($$
    INSERT INTO events.clicks VALUES
    (1, 101, 'view',     0),
    (2, 101, 'purchase', 19.99),
    (3, 102, 'purchase', 7.5),
    (4, 103, 'view',     0),
    (5, 104, 'refund',   -19.99)$$);

------------------------------------------------------------------------------
-- The "source of truth" Parquet file events.clicks was supposedly loaded from.
------------------------------------------------------------------------------
COPY (
    SELECT event_id::BIGINT AS event_id,
           user_id::INTEGER AS user_id,
           event_type,
           amount::DOUBLE   AS amount
    FROM (VALUES
        (1, 101, 'view',     0.0),
        (2, 101, 'purchase', 19.99),
        (3, 102, 'purchase', 7.05),
        (5, 104, 'refund',   -19.99),
        (6, 105, 'view',     0.0)
    ) t(event_id, user_id, event_type, amount)
) TO 'docker/clicks.parquet' (FORMAT parquet);
