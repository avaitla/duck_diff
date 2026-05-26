# duck_diff — Design (v1)

A focused DuckDB extension that diffs two relations on a single-column primary
key and reports, per key, whether it matched, differs, or exists on only one
side.

## Function family

| Function | Returns | Purpose |
|----------|---------|---------|
| `table_diff(left, right, key := 'id')` | table | one row per key: `pk_id`, `status`, `diff` |
| `table_diff_summary(left, right, key := 'id')` | 1-row table | counts per status |
| `tables_equal(left, right, key := 'id')` | BOOLEAN | fast equality check for CI/tests |

## Usage

```sql
LOAD duck_diff;

FROM table_diff(TABLE left_tbl, TABLE right_tbl, key := 'id');
```

Inputs are **relations**, so tables work today and `SELECT * FROM read_csv(...)`
or any subquery works without special-casing.

## Output of `table_diff`

| column | type | notes |
|--------|------|-------|
| `pk_id` | (key column's type) | `COALESCE(left.key, right.key)` |
| `status` | VARCHAR | `matched` / `differs` / `left_only` / `right_only` |
| `diff` | JSON | populated only for `differs`; NULL otherwise |

`diff` shape: `{"<col>": {"left": <val>, "right": <val>}, ...}` containing only
the columns whose values differ, with native types preserved.

Example:

| pk_id | status     | diff |
|-------|------------|------|
| 1     | matched    | NULL |
| 3     | left_only  | NULL |
| 5     | differs    | `{"number":{"left":1,"right":2},"email":{"left":"a@x","right":"b@x"}}` |
| 7     | right_only | NULL |

All four statuses are emitted (filter with `WHERE status <> 'matched'` if
desired).

## Semantics (v1 decisions)

- **PK**: single column only. Composite keys are a future extension.
- **NULL comparison**: `IS NOT DISTINCT FROM` — `NULL` equals `NULL` counts as
  matched.
- **Schema mismatch**: the two relations must have the same set of columns.
  Otherwise → error at bind time (message lists the differing columns).
- **Duplicate keys**: if the key is not unique on either side → error.
- **`matched` rows**: included in output.

## Implementation: Strategy A (bind-time SQL generation)

The table function introspects the two relations' schemas at bind time, then
generates a SQL plan that DuckDB executes. We lean on DuckDB's own join + JSON
engine rather than hand-writing execution.

Generated query (for inputs with key `id` and value columns `number`, `email`):

```sql
WITH l AS (SELECT * FROM <left relation>),
     r AS (SELECT * FROM <right relation>)
SELECT
    COALESCE(l.id, r.id) AS pk_id,
    CASE
        WHEN r.id IS NULL THEN 'left_only'
        WHEN l.id IS NULL THEN 'right_only'
        WHEN (l.number IS NOT DISTINCT FROM r.number)
         AND (l.email  IS NOT DISTINCT FROM r.email)  THEN 'matched'
        ELSE 'differs'
    END AS status,
    CASE WHEN l.id IS NOT NULL AND r.id IS NOT NULL THEN
        NULLIF(json_merge_patch(
            CASE WHEN l.number IS DISTINCT FROM r.number
                 THEN json_object('number', json_object('left', l.number, 'right', r.number))
                 ELSE '{}' END,
            CASE WHEN l.email IS DISTINCT FROM r.email
                 THEN json_object('email', json_object('left', l.email, 'right', r.email))
                 ELSE '{}' END
        ), '{}')
    END AS diff
FROM l FULL OUTER JOIN r ON l.id IS NOT DISTINCT FROM r.id;
```

Notes:
- `FULL OUTER JOIN` on `IS NOT DISTINCT FROM` yields all four statuses in one
  pass, NULL-key-safe.
- Per-column `json_object` + `json_merge_patch` includes only differing columns
  while preserving each column's native type (each `json_object` is typed
  independently before merge). `NULLIF(..., '{}')` collapses an empty result to
  NULL.
- Requires the bundled `json` extension to be available.

### Error checks (bind time, before generation)
- Schema mismatch: compare the column-name sets of both relations.
- Duplicate keys: `count(*) <> count(DISTINCT key)` guard per side.

## Out of scope for v1 (future)
- Composite / multi-column keys.
- Tolerant schema mode (diff shared columns, report added/dropped columns).
- `include_matched := false` and other output-shaping flags.
- Numeric tolerance / approximate comparison.
