---
name: sql-optimize
description: Iteratively optimize a slow SQL query's performance while proving every rewrite returns identical results — duck_diff is the correctness gate, timing is the fitness function. Use when asked to speed up, tune, or refactor a query/view/model without changing its output.
---

# SQL optimization with a duck_diff correctness gate

You are making a query faster. A rewrite is kept ONLY if it is both
measurably faster AND `table_diff` proves its output identical to the
original's. Because that check is mechanical, run this loop autonomously —
you verify your own correctness at every step; no human eyeballing needed.

## Setup (once)

1. `INSTALL duck_diff FROM community; LOAD duck_diff;`
2. Pin nondeterminism first or the diff is meaningless: `SET TimeZone = 'UTC';`
   parameterize `now()`/`random()`/`uuid()`; if the query ends in
   `ORDER BY … LIMIT n` with possible ties, make the ordering total.
3. Freeze the golden: `CREATE TABLE golden AS <original query>;` — run the
   original ONCE; every candidate compares against this frozen copy.
4. Pick the diff key. The output needs a unique key; if none exists,
   synthesize a deterministic one on BOTH sides (a rank computed with a
   total ORDER BY, or the full grouping key) — never `row_number()` over an
   unordered input.
5. Baseline timing: run the original 2–3 times (`.timer on` in the CLI, or
   time it from the host language), keep the best — first runs pay cold-read
   costs.

## The loop

Repeat until the target is met or 3 consecutive hypotheses fail to improve:

1. Form ONE rewrite hypothesis at a time, e.g.: quadratic self-join → window
   function; correlated subquery → join/window; kill `DISTINCT` that hides a
   join fanout; push filters/projections below joins; pre-aggregate before
   joining; materialize a reused CTE; drop unused columns; replace
   row-by-row UDF logic with set operations. `EXPLAIN ANALYZE` tells you
   where the time actually goes — read it before guessing.
2. `CREATE OR REPLACE TABLE candidate AS <rewrite>;` and record its time.
3. The gate:
   ```sql
   SELECT n_total = n_identical AS accepted
   FROM table_diff_summary('FROM golden', 'FROM candidate', pk := <key>);
   ```
4. Decide:
   - accepted AND meaningfully faster (>10%) → keep; this rewrite becomes
     the new current query (golden stays frozen).
   - accepted but not faster → revert, next hypothesis.
   - NOT accepted → the rewrite changed semantics. Inspect
     `FROM table_diff('FROM golden', 'FROM candidate', pk := <key>)
      WHERE diff_status <> 'identical' LIMIT 20;` to see how (ties broken
     differently, NULL handling, duplicate rows collapsed) — fix or discard.
     Never keep a faster-but-different rewrite; if the difference looks like
     an acceptable float/rounding artifact, surface the drifted rows and let
     the user decide on a `numeric_tolerance`.

## Report

A table of attempts — hypothesis, time, accepted/rejected and why — plus the
final SQL, the total speedup, and the acceptance query so it can be re-run.
Keep the golden and the gate around as a regression test for future edits.
