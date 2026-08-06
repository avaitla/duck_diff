-- Cross-warehouse refactor: a revenue rollup originally computed in Postgres
-- was rewritten on Snowflake. Same numbers?
--
-- Env vars used: PGHOST, PGPORT, PGDATABASE, PGUSER,
-- PGPASSWORD, SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD,
-- SNOWFLAKE_DATABASE, SNOWFLAKE_WAREHOUSE.

INSTALL postgres;
LOAD postgres;
INSTALL snowflake FROM community;
LOAD snowflake;

CREATE SECRET pg_prod (
    TYPE postgres,
    HOST     getenv('PGHOST'),
    PORT     getenv('PGPORT')::INTEGER,
    DATABASE getenv('PGDATABASE'),
    USER     getenv('PGUSER'),
    PASSWORD getenv('PGPASSWORD')
);
ATTACH '' AS pg (TYPE postgres, SECRET pg_prod, READ_ONLY);

-- snowflake_query() below references this secret by name.
CREATE SECRET snow (
    TYPE snowflake,
    ACCOUNT   getenv('SNOWFLAKE_ACCOUNT'),
    USER      getenv('SNOWFLAKE_USER'),
    PASSWORD  getenv('SNOWFLAKE_PASSWORD'),
    DATABASE  getenv('SNOWFLAKE_DATABASE'),
    WAREHOUSE getenv('SNOWFLAKE_WAREHOUSE')
);

-- Composite key: one row per (customer, month).
SELECT * FROM table_diff(
    $$ SELECT customer_id, order_month, order_count, revenue
       FROM pg.public.monthly_revenue $$,
    $$ FROM snowflake_query(
           'SELECT customer_id, order_month, order_count, revenue
            FROM marts.monthly_revenue', 'snow') $$,
    pk := ['customer_id', 'order_month'],
    require_matching_columns := false,
    upcast_types := true,           -- Postgres NUMERIC vs Snowflake NUMBER
    numeric_tolerance := 0.01       -- ignore sub-cent rounding differences
)
WHERE diff_status <> 'identical'
ORDER BY customer_id, order_month;
