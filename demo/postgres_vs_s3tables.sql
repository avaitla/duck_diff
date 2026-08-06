-- ETL audit: an OLTP Postgres table is synced (CDC/ETL) into an Amazon
-- S3 Tables bucket (managed Iceberg). Is the analytics copy faithful?
--
-- Env vars used: PGHOST, PGPORT, PGDATABASE, PGUSER,
-- PGPASSWORD, plus AWS credentials via the standard chain. The table-bucket
-- ARN below is configuration, not a secret — ATTACH requires a literal
-- string, so edit it in place.

INSTALL postgres;
LOAD postgres;
INSTALL iceberg;
LOAD iceberg;
INSTALL httpfs;
LOAD httpfs;
INSTALL aws;
LOAD aws;

CREATE SECRET pg_prod (
    TYPE postgres,
    HOST     getenv('PGHOST'),
    PORT     getenv('PGPORT')::INTEGER,
    DATABASE getenv('PGDATABASE'),
    USER     getenv('PGUSER'),
    PASSWORD getenv('PGPASSWORD')
);
ATTACH '' AS pg (TYPE postgres, SECRET pg_prod, READ_ONLY);

-- Signs both the S3 reads and the S3 Tables catalog requests.
CREATE SECRET aws_chain (TYPE s3, PROVIDER credential_chain);

-- EDIT ME: your table-bucket ARN (`aws s3tables list-table-buckets`).
ATTACH 'arn:aws:s3tables:us-east-1:111122223333:bucket/analytics-tables'
    AS s3tables (TYPE iceberg, ENDPOINT_TYPE s3_tables);

SELECT * FROM table_diff_summary(
    'FROM pg.public.customers',
    'FROM s3tables.crm.customers',
    pk := 'customer_id'
);

-- Which rows drifted and which columns are stale — ignoring the sync
-- pipeline's own bookkeeping column:
SELECT customer_id, diff_status, json_keys(diff_data) AS changed_columns
FROM table_diff(
    'FROM pg.public.customers',
    'FROM s3tables.crm.customers',
    pk := 'customer_id',
    ignore := ['synced_at']
)
WHERE diff_status <> 'identical'
ORDER BY customer_id;
