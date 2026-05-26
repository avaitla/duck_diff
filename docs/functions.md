# duck_diff function reference

All functions take two **relations** (`left`, `right`) and a single-column
primary key passed as the named parameter `key`.

---

## `table_diff`

Diffs `left` against `right` on `key`, emitting one row per distinct key value.

### Signature

```sql
table_diff(left, right, key := VARCHAR) -> TABLE
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `left` | relation | The "before" / left-hand relation. |
| `right` | relation | The "after" / right-hand relation. |
| `key` | `VARCHAR` (named) | Name of the single primary-key column. Must exist in both relations and be unique on each side. |

### Result columns

| Column | Type | Description |
|--------|------|-------------|
| `pk_id` | type of `key` | The key value (`COALESCE(left.key, right.key)`). |
| `status` | `VARCHAR` | `matched`, `differs`, `left_only`, or `right_only`. |
| `diff` | `JSON` | For `differs` rows, an object of the differing columns: `{"col": {"left": …, "right": …}}`. `NULL` for all other statuses. |

### Status meaning

| Status | Meaning |
|--------|---------|
| `matched` | Key present on both sides; all non-key columns equal (`IS NOT DISTINCT FROM`). |
| `differs` | Key present on both sides; at least one non-key column differs. |
| `left_only` | Key present only in `left`. |
| `right_only` | Key present only in `right`. |

### Examples

```sql
-- All changes between two tables
FROM table_diff(TABLE users_v1, TABLE users_v2, key := 'id');

-- Only the rows that changed
SELECT pk_id, diff
FROM table_diff(TABLE users_v1, TABLE users_v2, key := 'id')
WHERE status = 'differs';

-- Which keys were added on the right
SELECT pk_id
FROM table_diff(TABLE users_v1, TABLE users_v2, key := 'id')
WHERE status = 'right_only';

-- Pull a specific changed value out of the JSON diff
SELECT pk_id,
       diff -> 'email' ->> 'left'  AS old_email,
       diff -> 'email' ->> 'right' AS new_email
FROM table_diff(TABLE users_v1, TABLE users_v2, key := 'id')
WHERE diff -> 'email' IS NOT NULL;
```

### Errors

- **Schema mismatch** — `left` and `right` do not have the same set of columns.
- **Missing key** — `key` is not a column of both relations.
- **Duplicate keys** — `key` is not unique within `left` or within `right`.

---

## `table_diff_summary`

Returns a single row of counts, one per status. Useful for dashboards and quick
"how different are these?" checks without materializing every row.

### Signature

```sql
table_diff_summary(left, right, key := VARCHAR) -> TABLE
```

### Result columns

| Column | Type | Description |
|--------|------|-------------|
| `n_matched` | `BIGINT` | Keys present on both sides with all values equal. |
| `n_differs` | `BIGINT` | Keys present on both sides with at least one differing value. |
| `n_left_only` | `BIGINT` | Keys present only in `left`. |
| `n_right_only` | `BIGINT` | Keys present only in `right`. |

### Example

```sql
SELECT * FROM table_diff_summary(TABLE snap_a, TABLE snap_b, key := 'id');
-- n_matched | n_differs | n_left_only | n_right_only
-- ----------+-----------+-------------+-------------
--        2  |        1  |          1  |           1
```

---

## `tables_equal`

A scalar convenience for tests and CI: returns `true` when the two relations are
identical under the diff semantics (every key `matched`), `false` otherwise.

### Signature

```sql
tables_equal(left, right, key := VARCHAR) -> BOOLEAN
```

### Example

```sql
-- Fail a test if a transformation changed the data unexpectedly
SELECT tables_equal(TABLE expected, TABLE actual, key := 'id');  -- true / false
```

Equivalent to:

```sql
SELECT count(*) = 0
FROM table_diff(left, right, key := 'id')
WHERE status <> 'matched';
```
