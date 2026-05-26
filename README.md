# duck_diff

A focused DuckDB extension for diffing two relations on a primary key. Given a
"left" and a "right" relation, it reports — per key — whether the row
**matched**, **differs**, or exists only on one side, and (for differing rows)
exactly which columns changed.

```sql
LOAD duck_diff;

FROM table_diff('orders_before', 'orders_after', pk := 'order_id');
```

| order_id | diff_status | diff_data |
|----------|-------------|-----------|
| 1 | matched | NULL |
| 3 | left_only | NULL |
| 5 | differs | `{"amount":{"left":10,"right":12}}` |
| 7 | right_only | NULL |

The two relations are passed as **strings** — anything valid after `FROM`: a
table/view name, a table function, or a parenthesized subquery. So named tables,
CSV/Parquet, and ad-hoc queries all work:

```sql
FROM table_diff('read_csv(''before.csv'')', 'read_csv(''after.csv'')', pk := 'id');
FROM table_diff('(SELECT * FROM orders WHERE region = ''US'')', 'orders_v2', pk := 'id');
```

## Functions

See [docs/functions.md](docs/functions.md) for the full reference.

| Function | Returns | Purpose |
|----------|---------|---------|
| `table_diff(left, right, pk := …)` | table | one row per key: key column(s), `diff_status`, `diff_data` |
| `table_diff_summary(left, right, pk := …)` | one row | counts per status |
| `tables_equal(left, right, pk := …)` | BOOLEAN | true iff every key matched |

## Key features

- **Keys**: `pk := 'id'` (single) or `pk := 'region', additional_pk := ['id']`
  (composite). Key columns are emitted under their **original names**, so you can
  join the diff back to the source: `... JOIN orders USING (region, id)`.
- **Status**: `matched`, `differs`, `left_only`, `right_only`. NULL-safe
  comparison (`IS NOT DISTINCT FROM`, so `NULL` equals `NULL`).
- **`diff_data`** (JSON): for `differs` rows, only the columns that changed, as
  `{"col": {"left": …, "right": …}}`, with native types preserved.
- **Wide mode** (`wide := true`): expand each compared column into
  `<c>_left` / `<c>_right` / `<c>_diff` (and context into `<c>_left`/`<c>_right`)
  as real typed columns instead of JSON.
- **Schema policy**: `compare := 'strict'` (default — relations must match) or
  `'intersect'` (compare only common, same-typed columns). Refine with
  `columns := [...]` / `ignore := [...]`.
- **Context**: `context := ['name']` pulls those columns from both sides into
  `left_context` / `right_context` JSON columns — handy for understanding why a
  row is `left_only`/`right_only`.
- **Collisions**: meta columns default to a `diff_` prefix; override with
  `prefix := 'cmp_'` if a key column would clash.

## Building

```sh
GEN=ninja make    # build extension + a duckdb with it loaded (first build is slow)
build/release/test/unittest "test/sql/*"   # run the SQL test suite
```

The extension generates SQL using `json_object` / `json_merge_patch`, so the
bundled `json` extension is required (built in automatically for tests).

## Status

Single relation argument per DuckDB's table-function limit drives the
string-argument design (same pattern as the built-in `query()` /
`query_table()`). See [docs/DESIGN.md](docs/DESIGN.md) for the full design and
rationale.
