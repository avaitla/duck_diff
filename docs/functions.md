# duck_diff function reference

`table_diff` and `table_diff_summary` are table functions; `tables_equal` is a
scalar. The two relations are passed as **strings** — anything valid after
`FROM`: a table/view name, a table function (`read_csv(...)`,
`bigquery_query(...)`), or a parenthesized subquery. When the relation string
itself contains quotes, use DuckDB dollar-quoting to avoid escaping:
`$$ bigquery_query('bq', 'SELECT …') $$`. For diffing expensive remote sources
efficiently, see the caching notes in the
[README](../README.md#performance--caching).

---

## `table_diff`

Diffs `left` against `right` on a primary key, one output row per distinct key.

### Signature

```sql
table_diff(left, right,
           pk := 'id',                  -- required: string or list of column names
           additional_pk := [...],      -- extra key columns (composite key)
           compare := 'strict',          -- 'strict' (default) | 'intersect'
           columns := [...],             -- only compare these non-key columns
           ignore := [...],              -- exclude these columns from comparison
           prefix := 'diff_',            -- prefix for the meta output columns
           context := [...],             -- pull these columns from both sides
           wide := false)                -- expand columns instead of JSON diff_data
        -> TABLE
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `left`, `right` | VARCHAR | Relation expressions (table name, table function, or `(subquery)`). |
| `pk` | VARCHAR or LIST | **Required.** Primary key column(s). A string for a single key or a list. |
| `additional_pk` | LIST | Extra key columns appended to `pk` for a composite key. |
| `compare` | VARCHAR | `'strict'` (default): the relations must have identical column names and types. `'intersect'`: compare only columns present in both with matching types. |
| `columns` | LIST | Restrict the compared (non-key) columns to this list. |
| `ignore` | LIST | Exclude these columns from comparison. |
| `prefix` | VARCHAR | Prefix for the meta output columns (default `'diff_'`). |
| `context` | LIST | Columns pulled from **both** sides into `left_context` / `right_context`. Use `['*']` to pull in every non-key column not already compared — including columns present on only one side (the other side shows NULL). With `wide := true` this gives a full side-by-side of all columns (handy for dashboards). |
| `wide` | BOOLEAN | When `true`, expand each compared column into `<c>_left` / `<c>_right` / `<c>_diff` and each context column into `<c>_left` / `<c>_right`, instead of the JSON `diff_data` / `left_context` / `right_context` columns. Native types are preserved as real columns. |

### Output columns

| Column | Type | Description |
|--------|------|-------------|
| *key columns* | original types | The key column(s), under their **original names** (so you can join back with `USING`). |
| `<prefix>status` | VARCHAR | `matched` / `differs` / `left_only` / `right_only`. Default name `diff_status`. |
| `<prefix>columns` | VARCHAR[] | For `differs` rows, the names of the differing columns; NULL otherwise. Default name `diff_columns`. |
| `<prefix>data` | JSON | For `differs` rows, an object of the differing columns: `{"col": {"left": …, "right": …}}`. NULL otherwise. Default name `diff_data`. (Replaced by expanded columns in wide mode.) |
| `left_context` | JSON | Present only when `context` is set: the `context` columns from the left row, or NULL if the left row is absent. |
| `right_context` | JSON | As above, from the right row. |

### Status meaning

| Status | Meaning |
|--------|---------|
| `matched` | Key on both sides, all compared columns equal (`IS NOT DISTINCT FROM`). |
| `differs` | Key on both sides, at least one compared column differs. |
| `left_only` | Key present only in `left`. |
| `right_only` | Key present only in `right`. |

### Examples

```sql
-- Single key
FROM table_diff('users_v1', 'users_v2', pk := 'id');

-- CSV / parquet / any table function
FROM table_diff('read_csv(''before.csv'')', 'read_csv(''after.csv'')', pk := 'id');

-- Composite key; join the result back to the source with USING
SELECT d.*, o.name
FROM table_diff('orders', 'orders_v2', pk := 'region', additional_pk := ['id']) d
JOIN orders o USING (region, id);

-- Only the rows that changed, and what changed
SELECT id, diff_data
FROM table_diff('users_v1', 'users_v2', pk := 'id')
WHERE diff_status = 'differs';

-- Tolerant schema: compare only common, same-typed columns
FROM table_diff('a', 'b', pk := 'id', compare := 'intersect');

-- Ignore a column from comparison but keep it visible for context
FROM table_diff('a', 'b', pk := 'id', ignore := ['updated_at'], context := ['name']);

-- Wide mode: a column per side plus a per-column diff flag, types preserved
FROM table_diff('a', 'b', pk := 'id', wide := true);
-- id | diff_status | amount_left | amount_right | amount_diff | ...
```

### Errors

- **Missing `pk`** — the `pk` parameter is required.
- **Missing key** — a key column is not present in both relations.
- **Schema mismatch (strict)** — differing column sets, or a compared column whose type differs.
- **Duplicate keys** — the key is not unique within `left` or within `right`.
- **Name collision** — a key column collides with a meta output column; set `prefix`.

---

## `table_diff_summary`

Counts per status, one row. Same parameters as `table_diff`.

### Output columns

| Column | Type | Description |
|--------|------|-------------|
| `n_matched` | BIGINT | Keys on both sides, all values equal. |
| `n_differs` | BIGINT | Keys on both sides, at least one value differs. |
| `n_left_only` | BIGINT | Keys only in `left`. |
| `n_right_only` | BIGINT | Keys only in `right`. |
| `n_total` | BIGINT | Total distinct keys across both sides. |
| `pct_matched` / `pct_differs` / `pct_left_only` / `pct_right_only` | DOUBLE | Each count as a percentage of `n_total` (rounded to 2 decimals; NULL when there are no rows). |

```sql
SELECT * FROM table_diff_summary('snap_a', 'snap_b', pk := 'id');
-- n_matched | n_differs | n_left_only | n_right_only
--    2       |    1      |      1      |      1
```

---

## `tables_equal`

Scalar convenience: `true` when every key matched, `false` otherwise.

### Signature

```sql
tables_equal(left, right, pk := 'id', additional_pk := [...],
             compare := 'strict', columns := [...], ignore := [...])
        -> BOOLEAN
```

```sql
SELECT tables_equal('expected', 'actual', pk := 'id');  -- true / false
```

Equivalent to `SELECT count(*) = 0 FROM table_diff(...) WHERE diff_status <> 'matched'`.

---

## `schema_diff`

Compares the **column names and types** of two relations — no rows are read.
Returns one row per column (union of both schemas).

### Signature

```sql
schema_diff(left, right) -> TABLE
```

### Result columns

| Column | Type | Description |
|--------|------|-------------|
| `column_name` | VARCHAR | The column name. |
| `left_type` | VARCHAR | Its type on the left, or NULL if absent there. |
| `right_type` | VARCHAR | Its type on the right, or NULL if absent there. |
| `status` | VARCHAR | `matched` (same type both sides), `type_differs`, `left_only`, `right_only`. |

### Examples

```sql
-- full schema comparison
FROM schema_diff('orders', 'orders_v2');

-- just the mismatches
FROM schema_diff('orders', 'orders_v2') WHERE status <> 'matched';

-- do the schemas match at all?
SELECT count(*) = 0 AS schemas_match
FROM schema_diff('orders', 'orders_v2') WHERE status <> 'matched';
```

---

## Building a `columns` / `ignore` list from a query

`columns` / `ignore` take a list, and a named argument can't contain a subquery,
but you can compute the list once into a **variable** and pass it with
`getvariable(...)` — no string juggling:

```sql
-- ignore the columns whose name/type don't match between the two relations
SET VARIABLE mismatch = (
  SELECT list(column_name) FROM schema_diff('orders', 'orders_v2') WHERE status <> 'matched'
);
FROM table_diff('orders', 'orders_v2', pk := 'id', ignore := getvariable('mismatch'));

-- or pick columns straight from a relation's schema (DESCRIBE)
SET VARIABLE numeric_cols = (
  SELECT list(column_name) FROM (DESCRIBE SELECT * FROM orders)
  WHERE column_name <> 'id' AND column_type IN ('INTEGER','BIGINT','DOUBLE','DECIMAL')
);
FROM table_diff('orders', 'orders_v2', pk := 'id', columns := getvariable('numeric_cols'));
```
