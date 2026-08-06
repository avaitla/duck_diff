-- Replication integrity: does the MySQL RDS read replica match its primary?
-- Row-by-row and column-by-column, in the spirit of pt-table-checksum.
--
-- Env vars used: MYSQL_HOST, MYSQL_PORT, MYSQL_REPLICA_HOST,
-- MYSQL_REPLICA_PORT, MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD.

INSTALL mysql;
LOAD mysql;

-- Credentials come from the environment via getenv() — nothing is inlined
-- here, and DuckDB's secret manager redacts them in duckdb_secrets() output.
CREATE SECRET mysql_primary (
    TYPE mysql,
    HOST     getenv('MYSQL_HOST'),
    PORT     getenv('MYSQL_PORT')::INTEGER,
    DATABASE getenv('MYSQL_DATABASE'),
    USER     getenv('MYSQL_USER'),
    PASSWORD getenv('MYSQL_PASSWORD')
);

CREATE SECRET mysql_replica (
    TYPE mysql,
    HOST     getenv('MYSQL_REPLICA_HOST'),
    PORT     getenv('MYSQL_REPLICA_PORT')::INTEGER,
    DATABASE getenv('MYSQL_DATABASE'),
    USER     getenv('MYSQL_USER'),
    PASSWORD getenv('MYSQL_PASSWORD')
);

-- An empty ATTACH string defers entirely to the named secret.
ATTACH '' AS primary_db (TYPE mysql, SECRET mysql_primary, READ_ONLY);
ATTACH '' AS replica_db (TYPE mysql, SECRET mysql_replica, READ_ONLY);

-- Health check: one row of counts — in sync means everything is n_identical.
SELECT * FROM table_diff_summary(
    'FROM primary_db.orders',
    'FROM replica_db.orders',
    pk := 'id'
);

-- Drill down: each drifted row with the exact columns that changed. On a busy
-- table expect some churn from replication lag; for a strict check, restrict
-- both sides to rows that have stopped moving, e.g.
--   'SELECT * FROM primary_db.orders WHERE updated_at < now() - INTERVAL 5 MINUTE'
SELECT id, diff_status, diff_data
FROM table_diff(
    'FROM primary_db.orders',
    'FROM replica_db.orders',
    pk := 'id'
)
WHERE diff_status <> 'identical'
ORDER BY id;
