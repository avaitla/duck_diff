# duck_diff function reference

`table_diff`, `table_diff_summary`, and `schema_diff` are table functions. The
two relations are passed as **query strings**, written the way you
would in SQL — a `FROM …` clause or a full `SELECT … FROM …`. This mirrors the
built-in `query()` function: `'FROM orders'`, `'FROM read_csv(''x.csv'')'`,
`'SELECT id, amount FROM orders WHERE region = ''EU'''` all work; a bare name
like `'orders'` is **not** a query and is rejected (write `'FROM orders'`).
When the string itself contains quotes, use DuckDB dollar-quoting to avoid
escaping: `$$ FROM bigquery_query('bq', 'SELECT …') $$`. For diffing expensive
remote sources efficiently, see the caching notes in the
[README](../README.md#performance--caching).

---

## `table_diff`

Diffs `left` against `right` on a primary key, one output row per distinct key.

### Signature

```sql
table_diff(left, right,
           pk := 'id',                  -- required: a column name, or a list ['a','b'] for a composite key
           require_matching_columns := true,  -- both sides must have identical columns (names+types)
           upcast_types := false,        -- reconcile differing types via their common super-type
           numeric_tolerance := NULL,    -- treat numbers within this band as equal
           timestamp_precision := NULL,  -- truncate timestamps to this part before comparing
           null_equals_empty := false,   -- treat NULL and '' as equal (VARCHAR)
           columns := [...],             -- only compare these non-key columns
           ignore := [...],              -- exclude these columns from comparison
           prefix := 'diff_',            -- prefix for the meta output columns
           context := [...])             -- also expand these non-compared columns
        -> TABLE
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `left`, `right` | VARCHAR | Query strings — a `FROM …` clause or a full `SELECT … FROM …` (a bare name is rejected; write `FROM tbl`). |
| `pk` | VARCHAR or LIST | **Required.** Primary key column(s): a string for a single key, or a list `['a','b']` for a composite key. |
| `require_matching_columns` | BOOLEAN | Default `true`: both relations must have an **identical** column set — same names *and* types — else error. Set `false` to compare only the columns common to both sides (one-sided columns dropped). |
| `upcast_types` | BOOLEAN | Default `false`. When `true`, a key or compared column whose type differs across the two sides is reconciled to their **common super-type** (e.g. BIGINT vs INTEGER) instead of being treated as a mismatch. Requires `require_matching_columns := false` (matching columns already demands identical types). See [Cross-type comparison](#cross-type-comparison). |
| `numeric_tolerance` | DOUBLE | When set (≥ 0), two numeric values count as equal if `abs(left - right) <= numeric_tolerance`. Applies to numeric compared columns only (not keys). |
| `timestamp_precision` | VARCHAR | When set, timestamp compared columns are truncated with `date_trunc(precision, …)` before comparing (e.g. `'second'`, `'minute'`, `'day'`). Useful when engines differ in sub-second precision. Compared columns only. |
| `null_equals_empty` | BOOLEAN | Default `false`. When `true`, SQL `NULL` and the empty string `''` compare as equal for VARCHAR compared columns. |
| `columns` | LIST | Restrict the compared (non-key) columns to this list. |
| `ignore` | LIST | Exclude these columns from comparison. |
| `prefix` | VARCHAR | Prefix for the meta output columns (default `'diff_'`). |
| `context` | LIST | Also expand these **non-compared** columns as `<c>_left` / `<c>_right` (no `_diff_status`, since they are not compared). Use `['*']` for **every non-key column**; a one-sided row shows NULL on the absent side, so this surfaces the full row for `left_only` / `right_only` rows (which have no `diff_data`). |

### Output columns

| Column | Type | Description |
|--------|------|-------------|
| *key columns* | original types | The key column(s), under their **original names** (so you can join back with `USING`). |
| `<prefix>status` | VARCHAR | `identical` / `different` / `left_only` / `right_only`. Default name `diff_status`. |
| `<prefix>data` | JSON | For `different` rows, an object of the differing columns: `{"col": {"left": …, "right": …}}`. NULL otherwise. Default name `diff_data`. (The differing column names are `json_keys(diff_data)`.) |
| `<c>_left`, `<c>_right` | original types | Per **compared** column: its value on each side (native type), NULL on the absent side of a one-sided row. |
| `<c>_diff_status` | VARCHAR | Per **compared** column: `identical` / `different` / `left_only` / `right_only`, mirroring the row status. |
| `<c>_left`, `<c>_right` | original types | Per **context** column (from `context`): value on each side, with no `_diff_status` (not compared). |

### Status meaning

| Status | Meaning |
|--------|---------|
| `identical` | Key on both sides, all compared columns equal (`IS NOT DISTINCT FROM`). |
| `different` | Key on both sides, at least one compared column differs. |
| `left_only` | Key present only in `left`. |
| `right_only` | Key present only in `right`. |

### Examples

```sql
-- Single key
FROM table_diff('FROM users_v1', 'FROM users_v2', pk := 'id');

-- CSV / parquet / any table function
FROM table_diff('FROM read_csv(''before.csv'')', 'FROM read_csv(''after.csv'')', pk := 'id');

-- Composite key; join the result back to the source with USING
SELECT d.*, o.name
FROM table_diff('FROM orders', 'FROM orders_v2', pk := ['region', 'id']) d
JOIN orders o USING (region, id);

-- Only the rows that changed, and what changed
SELECT id, diff_data
FROM table_diff('FROM users_v1', 'FROM users_v2', pk := 'id')
WHERE diff_status = 'different';

-- Tolerant schema: compare only the columns common to both sides
FROM table_diff('FROM a', 'FROM b', pk := 'id', require_matching_columns := false);

-- Also reconcile differing types via their common super-type (BIGINT vs
-- INTEGER, BOOLEAN vs BIGINT, … — common when diffing across engines)
FROM table_diff('FROM a', 'FROM b', pk := 'id', require_matching_columns := false, upcast_types := true);

-- Ignore a column from comparison but keep it visible (as updated_at_left/right)
FROM table_diff('FROM a', 'FROM b', pk := 'id', ignore := ['updated_at'], context := ['updated_at']);

-- The expanded per-column columns are always present alongside diff_data:
-- id | diff_status | diff_data | amount_left | amount_right | amount_diff_status | ...
SELECT id, amount_left, amount_right, amount_diff_status
FROM table_diff('FROM a', 'FROM b', pk := 'id') WHERE amount_diff_status = 'different';
```

### Errors

- **Missing `pk`** — the `pk` parameter is required.
- **Missing key** — a key column is not present in both relations.
- **Schema mismatch** — under `require_matching_columns := true` (default): differing column sets, or a compared column whose type differs (and `upcast_types` is off).
- **Contradictory flags** — `require_matching_columns := true` combined with `upcast_types := true`.
- **Duplicate keys** — the key is not unique within `left` or within `right`.
- **Name collision** — a key column collides with a meta output column; set `prefix`.

---

## `table_diff_summary`

Counts per status, one row. Same parameters as `table_diff`.

### Output columns

| Column | Type | Description |
|--------|------|-------------|
| `n_identical` | BIGINT | Keys on both sides, all values equal. |
| `n_different` | BIGINT | Keys on both sides, at least one value different. |
| `n_left_only` | BIGINT | Keys only in `left`. |
| `n_right_only` | BIGINT | Keys only in `right`. |
| `n_total` | BIGINT | Total distinct keys across both sides. |
| `pct_identical` / `pct_different` / `pct_left_only` / `pct_right_only` | DOUBLE | Each count as a percentage of `n_total` (rounded to 2 decimals; NULL when there are no rows). |

```sql
SELECT * FROM table_diff_summary('FROM snap_a', 'FROM snap_b', pk := 'id');
-- n_identical | n_different | n_left_only | n_right_only
--    2       |    1      |      1      |      1
```

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
| `status` | VARCHAR | `identical` (same type both sides), `type_differs`, `left_only`, `right_only`. |

### Examples

```sql
-- full schema comparison
FROM schema_diff('FROM orders', 'FROM orders_v2');

-- just the mismatches
FROM schema_diff('FROM orders', 'FROM orders_v2') WHERE status <> 'identical';

-- do the schemas match at all?
SELECT count(*) = 0 AS schemas_match
FROM schema_diff('FROM orders', 'FROM orders_v2') WHERE status <> 'identical';
```

---

## Building a `columns` / `ignore` list from a query

`columns` / `ignore` take a list, and a named argument can't contain a subquery,
but you can compute the list once into a **variable** and pass it with
`getvariable(...)` — no string juggling:

```sql
-- ignore the columns whose name/type don't match between the two relations
SET VARIABLE mismatch = (
  SELECT list(column_name) FROM schema_diff('FROM orders', 'FROM orders_v2') WHERE status <> 'identical'
);
FROM table_diff('FROM orders', 'FROM orders_v2', pk := 'id', ignore := getvariable('mismatch'));

-- or pick columns straight from a relation's schema (DESCRIBE)
SET VARIABLE numeric_cols = (
  SELECT list(column_name) FROM (DESCRIBE SELECT * FROM orders)
  WHERE column_name <> 'id' AND column_type IN ('INTEGER','BIGINT','DOUBLE','DECIMAL')
);
FROM table_diff('FROM orders', 'FROM orders_v2', pk := 'id', columns := getvariable('numeric_cols'));
```

---

## Cross-type comparison

Two independent boolean flags control how strictly the two schemas must line up.
Both default to the safe choice for same-engine diffs; relax them to diff across
engines (e.g. BigQuery vs MySQL), where the *same* logical column often lands on
a different physical type.

| `require_matching_columns` | `upcast_types` | Behavior |
|:---:|:---:|---|
| `true` *(default)* | `false` | **Strict.** Identical column set required (same names and types); any difference errors. |
| `false` | `false` | Compare only columns present on **both** sides; one-sided **and** type-mismatched columns are dropped. |
| `false` | `true` | Compare only common columns, and reconcile a differing type to the **common super-type** instead of dropping it. |
| `true` | `true` | **Illegal** — requiring matching columns already demands identical types, so upcasting them is contradictory (error). |

### Type reconciliation (`upcast_types := true`)

Each differing key/column is reconciled to the **common super-type** of the two
sides (DuckDB's implicit cast lattice) and the widened values are compared:

| Left | Right | Reconciled as | Notes |
|------|-------|---------------|-------|
| `BIGINT` | `INTEGER` | `BIGINT` | The common cross-engine case. |
| `INTEGER` | `DOUBLE` | `DOUBLE` | |
| `BOOLEAN` | `BIGINT` | `BIGINT` | `false`/`true` compare as `0`/`1`. |
| `INTEGER[]` | `VARCHAR` | *(none)* | No common type → column dropped. |

This applies to both **key columns** (the join and the projected key widen to
the common type) and **compared columns**. A *compared* column with no common
type is silently dropped; a *key* column with no common type is still an error,
since keys cannot be dropped.

```sql
-- BigQuery (BIGINT ids) vs MySQL (INTEGER ids): the default errors on the
-- type mismatch; relax both flags to diff across the engines
FROM table_diff(
  'FROM bigquery_query(''bq'', ''SELECT * FROM nocd_v2.member_invoices'')',
  'FROM mysql_query(''mysql_db_1'', ''SELECT * FROM nocd_v2.member_invoices'')',
  pk := 'id',
  require_matching_columns := false,
  upcast_types := true
);
```

> **Note on implicit casts.** Reconciliation uses DuckDB's implicit cast rules,
> so a `BOOLEAN` compared against an integer column is widened to the integer
> (`false`/`true` → `0`/`1`) rather than reported as a difference. That is
> usually what you want when a MySQL `tinyint(1)` and a BigQuery `INT64` model
> the same flag — but it is a real semantic cast, so set `upcast_types := true`
> deliberately. To see the raw, un-reconciled type differences instead, use
> `schema_diff`, which always reports the original types literally.

---

## Value normalization

Beyond *type* reconciliation, three flags loosen how *values* are compared —
the usual cross-engine noise. They apply to **compared columns only** (never to
keys, which always join exactly) and they affect only the equality decision:
`diff_data` and the expanded `<c>_left`/`<c>_right` columns still report the **raw** values (only `<c>_diff_status` reflects the normalized comparison).

| Flag | Effect |
|------|--------|
| `numeric_tolerance := <n>` | Numeric columns count as equal when `abs(left - right) <= n`. A one-sided NULL is still a difference (it is in no band). |
| `timestamp_precision := '<part>'` | Timestamp columns are compared after `date_trunc('<part>', …)` — e.g. `'second'` ignores sub-second drift, `'day'` ignores time-of-day. |
| `null_equals_empty := true` | `NULL` and `''` compare as equal for VARCHAR columns (one engine storing `''` where another stores `NULL`). |

```sql
-- floats within a cent, timestamps to the second, NULL == '' all treated as equal
FROM table_diff('FROM snap_a', 'FROM snap_b', pk := 'id',
                numeric_tolerance := 0.01,
                timestamp_precision := 'second',
                null_equals_empty := true);
```

> These knobs live on `table_diff` and `table_diff_summary`.
