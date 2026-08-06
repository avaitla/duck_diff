# Converting SQL between dialects with Claude, using duck_diff as the acceptance loop

LLMs are very good at translating SQL between dialects (Postgres → Snowflake,
MySQL → BigQuery, Oracle → DuckDB, …) and very bad at *knowing* when they got
it right. `table_diff` closes that gap: it gives the agent a machine-checkable
definition of done — **the converted query produces byte-identical rows** —
so the agent can iterate against ground truth instead of guessing.

## The loop

1. **Extract the sources, then freeze everything.** List every source table
   the query reads (`FROM` / `JOIN` / CTE inputs), snapshot each into a local
   DuckDB table, then run the original query once on the source engine and
   freeze its output as the golden. Every later iteration compares against
   these frozen tables — neither the inputs nor the expected output can
   drift under you, and nothing re-hits the source system:

   ```sql
   -- duckdb migration_cache.db
   CREATE TABLE IF NOT EXISTS src_orders    AS FROM postgres_query('pg', 'SELECT * FROM public.orders');
   CREATE TABLE IF NOT EXISTS src_customers AS FROM postgres_query('pg', 'SELECT * FROM public.customers');
   CREATE TABLE IF NOT EXISTS golden_rollup AS FROM postgres_query('pg', '<the original query>');
   ```

   When the target is DuckDB itself, the converted query reads the `src_*`
   snapshots directly — transpile, run, diff, all locally. When the target is
   another warehouse, the snapshots are your stable reference while the
   converted query runs over the target's copy of the data.

2. **Shape first.** `schema_diff` before any row comparison — a missing or
   retyped column explains most early failures in one glance:

   ```sql
   FROM schema_diff('FROM golden_orders', $$ <converted query> $$)
   WHERE status <> 'identical';
   ```

3. **Convert one section at a time.** One CTE, one view, one dbt model — not
   the whole 800-line query. Each section gets its own accept/reject verdict,
   so a failure points at tens of lines, not hundreds.

4. **Accept only on a clean diff.**

   ```sql
   SELECT n_total = n_identical AS accepted
   FROM table_diff_summary('FROM golden_orders', $$ <converted query> $$,
                           pk := 'order_id');
   ```

5. **On failure, feed the drift back — not the whole table.** The two most
   useful failure artifacts for an agent are *which columns* drift and a
   *small sample* of drifted rows:

   ```sql
   -- which columns changed, ranked
   SELECT unnest(json_keys(diff_data)) AS col, count(*) AS n
   FROM table_diff('FROM golden_orders', $$ … $$, pk := 'order_id')
   WHERE diff_status = 'different' GROUP BY col ORDER BY n DESC;

   -- twenty concrete counterexamples
   FROM table_diff('FROM golden_orders', $$ … $$, pk := 'order_id')
   WHERE diff_status <> 'identical' LIMIT 20;
   ```

6. Repeat 3–5 until every section is accepted.

## Why this works so well for autonomous agents

The scarce resource in agentic work isn't generation — it's **verification**.
An agent editing SQL normally has to argue its change is correct; with
duck_diff the argument is replaced by a check the agent runs itself:
`n_total = n_identical` is true or it isn't. That property is what makes it
safe to let Claude run long loops unattended:

- **Self-validation** — every step ends in a machine verdict, so the agent
  catches its own mistakes immediately instead of compounding them.
- **No rationalization** — "looks equivalent to me" is not an available
  move; the acceptance query cannot be talked around.
- **Tight feedback** — failures come with data (which columns, which rows),
  so the next attempt is informed, not a re-roll.

The same gate powers three autonomous loops, shipped as skills in
[`.claude/skills/`](../.claude/skills/): **sql-migrate** (dialect
conversion, below), **sql-optimize** (make it faster, prove the answer
didn't change), and **etl-check** (is the copy in sync — and repair only
the drift).

### Pairing with Claude Code's `/goal`

[`/goal`](https://code.claude.com/docs/en/goal) (Claude Code v2.1.139+) keeps
Claude working across turns until a completion condition verifiably holds —
exactly the shape of these loops. duck_diff supplies the condition as
something the goal evaluator can check from the transcript, because Claude
prints a literal `true`/`false` each round:

```text
/goal every source table reports/orders_rollup.sql reads is snapshotted into
migration_cache.db, every section is converted to BigQuery dialect, and for
each section the acceptance query
SELECT n_total = n_identical FROM table_diff_summary(...) has been run and
returned true in this session — or you hit a tolerance decision that needs me
```

Works the same for the other loops: "the candidate query is ≥5× faster than
baseline AND the diff gate returned true", or "the converge script reruns
until table_diff_summary reports 100% n_identical". Vague goals ("the
migration is done") make the evaluator guess; goals phrased around the
printed diff verdict don't. Pair with auto mode for unattended tool calls,
and add "or stop after N turns" as a bound.

## Giving this to Claude: the `sql-migrate` skill

This repo packages the whole workflow as a Claude Code **skill** at
[`.claude/skills/sql-migrate/SKILL.md`](../.claude/skills/sql-migrate/SKILL.md).
Any Claude Code session opened in this repository picks it up automatically —
ask for a migration (or run `/sql-migrate`) and Claude follows the loop below
with the acceptance rule built in.

To use it from **other** projects, copy the folder to your personal skills
directory, where it loads in every session:

```sh
cp -r .claude/skills/sql-migrate ~/.claude/skills/
```

(Teams can also ship it in the target repo's `.claude/skills/`, or distribute
it as a plugin.) If you'd rather not install anything, the one-shot prompt
below carries the same rules.

## A prompt that runs the loop

Paste something like this into Claude Code (adjust paths/connectors):

```text
Convert reports/orders_rollup.sql from Postgres dialect to BigQuery dialect,
section by section. Work under these rules:

1. Acceptance is mechanical, not judgment: a section is DONE only when
     SELECT n_total = n_identical FROM table_diff_summary(
       'FROM golden_<section>', '<converted section>', pk := '<key>')
   returns true against the golden snapshots in migration_cache.db.
   Run it after every change. Do not declare success without it.
2. Convert ONE section (CTE/subquery) at a time, in dependency order.
   Materialize each converted section's output and use it as the input
   for the next, so errors don't compound.
3. When a diff fails, first run schema_diff, then pull the changed-column
   histogram and 20 sample rows (WHERE diff_status <> 'identical' LIMIT 20),
   diagnose, fix, and re-run the acceptance query.
4. Do not stop, summarize, or ask for confirmation until every section
   passes, or you hit a difference that requires a business decision
   (rounding, timezone, collation) — in that case, show the exact drifted
   rows and the smallest tolerance option that would accept them
   (numeric_tolerance / timestamp_precision / null_equals_empty), and wait.
5. Keep a scratch log of sections converted and their diff counts.
```

The important properties: the agent has a **stop condition it cannot
rationalize around** (rule 1), a **granularity that keeps failures small**
(rule 2), a **debugging recipe** (rule 3), and **permission to keep going**
(rule 4) — which is what "don't stop until it's converted" needs in practice.

## Tolerances are decisions, not fixes

`numeric_tolerance`, `timestamp_precision`, and `null_equals_empty` exist
because engines genuinely disagree (float summation order, sub-second
precision, `''` vs NULL). They are the right tool for *known, accepted*
differences — and the wrong tool for making a red diff green. The prompt
above deliberately makes the agent surface the drifted rows and *propose*
a tolerance rather than apply one silently; a human accepts it.

Two more things that keep the loop honest:

- **Pin the environment**: `SET TimeZone = 'UTC';` and avoid nondeterministic
  functions (`now()`, `random()`, `uuid()`) in the queries being compared —
  parameterize them instead.
- **Keep the goldens in CI** afterwards: the same `table_diff` calls that
  accepted the migration make a regression suite — see
  [examples/](../examples/) for the sqllogictest pattern.
