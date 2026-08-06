-- Lakehouse migration: an Iceberg table is being moved to DuckLake, with a
-- Postgres database as the DuckLake catalog (metadata) and S3 for data files.
-- Verify the copy before cutting over.
--
-- Env vars used: ICEBERG_ORDERS_PATH, DUCKLAKE_DATA_PATH,
-- DUCKLAKE_PG_HOST, DUCKLAKE_PG_PORT, DUCKLAKE_PG_DATABASE, DUCKLAKE_PG_USER,
-- DUCKLAKE_PG_PASSWORD, plus AWS credentials via the standard chain.

INSTALL iceberg;
LOAD iceberg;
INSTALL ducklake;
LOAD ducklake;
INSTALL postgres;
LOAD postgres;
INSTALL httpfs;
LOAD httpfs;
INSTALL aws;
LOAD aws;

-- One S3 secret covers both sides: the Iceberg warehouse we scan directly and
-- the bucket DuckLake keeps its data files in.
CREATE SECRET aws_chain (TYPE s3, PROVIDER credential_chain);

-- The Postgres database holding the DuckLake catalog:
CREATE SECRET lake_catalog_pg (
    TYPE postgres,
    HOST     getenv('DUCKLAKE_PG_HOST'),
    PORT     getenv('DUCKLAKE_PG_PORT')::INTEGER,
    DATABASE getenv('DUCKLAKE_PG_DATABASE'),
    USER     getenv('DUCKLAKE_PG_USER'),
    PASSWORD getenv('DUCKLAKE_PG_PASSWORD')
);

-- Wire DuckLake together: metadata in Postgres (via the secret above), data
-- files in S3. All connection material stays in the environment.
CREATE SECRET lake_cfg (
    TYPE ducklake,
    METADATA_PATH '',
    DATA_PATH getenv('DUCKLAKE_DATA_PATH'),
    METADATA_PARAMETERS MAP {'TYPE': 'postgres', 'SECRET': 'lake_catalog_pg'}
);
ATTACH 'ducklake:lake_cfg' AS lake (READ_ONLY);

SELECT * FROM table_diff_summary(
    $$ FROM iceberg_scan(getenv('ICEBERG_ORDERS_PATH')) $$,
    $$ FROM lake.orders $$,
    pk := 'order_id'
);

-- If anything differs, name the rows and the columns:
SELECT order_id, diff_status, diff_data
FROM table_diff(
    $$ FROM iceberg_scan(getenv('ICEBERG_ORDERS_PATH')) $$,
    $$ FROM lake.orders $$,
    pk := 'order_id'
)
WHERE diff_status <> 'identical'
ORDER BY order_id;
