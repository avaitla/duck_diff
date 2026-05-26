# duck_diff — Design

A focused DuckDB extension that diffs two relations on a primary key and
reports, per key, whether it matched, differs, or exists only on one side.

## Function family

| Function | Returns | Purpose |
|----------|---------|---------|
| `table_diff(left, right, pk := …)` | table | one row per key: key column(s), `diff_status`, `diff_data` |
| `table_diff_summary(left, right, pk := …)` | 1-row table | counts per status |
| `tables_equal(left, right, pk := …)` | BOOLEAN | fast equality check for CI/tests |

## Inputs are strings

A DuckDB table function may have **at most one** subquery/`TABLE` parameter
(enforced by the binder), so two-relation `TABLE a, TABLE b` syntax is
impossible. Instead, `left` and `right` are VARCHAR relation expressions —
anything valid after `FROM` — mirroring the built-in `query()` / `query_table()`
functions. This keeps tables, CSV/Parquet, and subqueries on one code path.

```sql
FROM table_diff('orders', 'orders_v2', pk := 'id');
FROM table_diff('read_csv(''a.csv'')', 'read_csv(''b.csv'')', pk := 'id');
```

## Output

`table_diff` emits, in order: the key column(s) under their **original names**
(so the result joins back to the source with `USING`), then `<prefix>status`
and `<prefix>data` (prefix defaults to `diff_`), then `left_context` /
`right_context` when `context` is set.

| order_id | diff_status | diff_data |
|----------|-------------|-----------|
| 1 | matched | NULL |
| 3 | left_only | NULL |
| 5 | differs | `{"amount":{"left":10,"right":12}}` |
| 7 | right_only | NULL |

`diff_data` (JSON) contains only the differing columns, `{"col":{"left":…,
"right":…}}`, preserving native types; NULL except for `differs`.

## Semantics

- **Key**: required. `pk := 'id'` (string or list) plus optional
  `additional_pk` for composite keys.
- **NULL comparison**: `IS NOT DISTINCT FROM` — `NULL` equals `NULL`.
- **Schema policy**: `compare := 'strict'` (default; identical column names and
  types required, else error) or `'intersect'` (compare only common, same-typed
  columns; others silently dropped). `columns` / `ignore` refine the set.
- **Duplicate keys**: error (key must be unique on both sides).
- **Context**: `context := [...]` pulls those columns from both sides into
  `left_context` / `right_context`, NULL where a side's row is absent.
- **Collisions**: a key column clashing with a meta column is an error; set
  `prefix` to move the meta columns.

## Implementation: bind-time SQL generation

The table functions use `bind_replace`. At bind time we introspect each
relation's schema (by binding `SELECT * FROM <relation>` — no data read, no temp
tables), reconcile columns/types per `compare`, validate keys, then generate a
single query that DuckDB executes:

```sql
WITH __l AS (SELECT *, TRUE AS __p FROM (<left>)),
     __r AS (SELECT *, TRUE AS __p FROM (<right>))
SELECT COALESCE(l.k, r.k) AS k,
       CASE WHEN r.__p IS NULL THEN 'left_only'
            WHEN l.__p IS NULL THEN 'right_only'
            WHEN <all value cols IS NOT DISTINCT FROM> THEN 'matched'
            ELSE 'differs' END AS diff_status,
       CASE WHEN l.__p AND r.__p AND NOT (<all equal>)
            THEN json_merge_patch('{}', <per-column diff objects>) END AS diff_data
FROM __l l FULL OUTER JOIN __r r ON l.k IS NOT DISTINCT FROM r.k
WHERE (CASE WHEN <duplicate key exists> THEN error('…') END) IS NULL;
```

- `FULL OUTER JOIN` on `IS NOT DISTINCT FROM` yields all four statuses NULL-safe.
- A `TRUE AS __p` marker per side distinguishes presence from NULL key values.
- Per-column `json_object` + variadic `json_merge_patch` (seeded with `'{}'`)
  includes only differing columns while preserving each column's type.
- Duplicate keys are detected with a `GROUP BY … HAVING count(*) > 1` guard that
  raises via the `error()` scalar.

Requires the bundled `json` extension. `tables_equal` is a SQL macro wrapping
`table_diff`.

## Out of scope (future)
- No-key / set-difference mode (we require a pk).
- Numeric tolerance / approximate comparison.
- Multiset (duplicate-row) semantics.
