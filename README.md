# duck_diff

A focused DuckDB extension for diffing two relations on a single-column primary
key. Given a "left" and a "right" relation, it reports — per key — whether the
row **matched**, **differs**, or exists only on one side, and (for differing
rows) exactly which columns changed.

```sql
LOAD duck_diff;

FROM table_diff(TABLE orders_before, TABLE orders_after, key := 'order_id');
```

| pk_id | status     | diff |
|-------|------------|------|
| 1     | matched    | NULL |
| 3     | left_only  | NULL |
| 5     | differs    | `{"amount":{"left":10,"right":12},"status":{"left":"open","right":"paid"}}` |
| 7     | right_only | NULL |

Inputs are **relations**, so anything that produces rows works — tables, views,
CTEs, subqueries, or `read_csv` / `read_parquet`:

```sql
FROM table_diff(
    (SELECT * FROM read_csv('before.csv')),
    (SELECT * FROM read_csv('after.csv')),
    key := 'id'
);
```

## Functions

See [docs/functions.md](docs/functions.md) for the full reference.

| Function | Returns | Purpose |
|----------|---------|---------|
| `table_diff(left, right, key := 'id')` | table | one row per key: `pk_id`, `status`, `diff` |
| `table_diff_summary(left, right, key := 'id')` | one row | counts per status |
| `tables_equal(left, right, key := 'id')` | `BOOLEAN` | true iff every key matched |

## Semantics

- **Primary key**: a single column (composite keys are not yet supported).
- **Status** is one of `matched`, `differs`, `left_only`, `right_only`.
- **NULL-safe comparison**: values are compared with `IS NOT DISTINCT FROM`, so
  `NULL` equals `NULL` (counts as matched).
- **`diff`** is a `JSON` value populated only for `differs` rows. It contains
  only the columns whose values differ, as `{"col": {"left": …, "right": …}}`,
  preserving each column's native type.

### Errors (v1 is strict)

- The two relations must have the **same set of columns**, otherwise an error is
  raised.
- The `key` must be **unique** on both sides; duplicate keys raise an error.

## Building

```sh
make            # build extension + a duckdb with it loaded
make test       # run the SQL test suite in test/sql/
```

The extension generates SQL that uses `json_object` / `json_merge_patch`, so the
bundled `json` extension is required (built in automatically for tests).

## Status

v1 is single-key, strict-schema. Planned: composite keys, a tolerant-schema
mode (diff shared columns, report added/dropped columns), and output-shaping
flags. See [docs/DESIGN.md](docs/DESIGN.md).
