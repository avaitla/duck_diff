#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["duckdb>=1.1"]
# ///
"""Run a duck_diff table diff and open an interactive report web page.

Single-file script with inline dependency metadata (PEP 723): run it with
`uv run diff_report.py …` — uv provisions Python + the duckdb package on the
fly, no venv or pip install needed.

Examples:

    # two local files
    uv run diff_report.py \
        --left "FROM read_csv('a.csv')" --right "FROM read_csv('b.csv')" --pk id

    # cross-database: point --setup at any connection preamble, e.g. the
    # ATTACH/secret blocks from the demos in this directory. getenv('X')
    # calls in the setup SQL are rewritten from this process's environment
    # (getenv() itself is a duckdb-CLI-only function).
    export PGHOST=… PGPASSWORD=… CLICKHOUSE_URL=… CLICKHOUSE_USER=… CLICKHOUSE_PASSWORD=…
    uv run diff_report.py --setup setup_pg_ch.sql \
        --left  "SELECT id, email, plan FROM pg.public.customers" \
        --right "FROM clickhouse_query('SELECT id, email, plan FROM appdb.customers FINAL')" \
        --pk id --upcast --timestamp-precision second

    # serve over HTTP instead of opening the file directly
    uv run diff_report.py --left … --right … --pk id --serve

Unlike report.sh (which turns the CLI's HTML mode into a page row by row),
this script embeds the diff as JSON and renders it client-side, so filtering,
sorting, and status chips stay snappy into the hundreds of thousands of rows —
only a window of matching rows is materialized in the DOM at a time.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import re
import sys
import webbrowser
from pathlib import Path

import duckdb


def sql_str(value: str) -> str:
    """Quote a value as a SQL single-quoted string literal."""
    return "'" + value.replace("'", "''") + "'"


def rewrite_getenv(sql: str) -> str:
    """Replace getenv('VAR') with the value from this process's environment.

    getenv() only exists in the duckdb CLI; this lets the demo .sql setup
    blocks run unmodified from Python while credentials stay in the
    environment.
    """

    def sub(m: re.Match[str]) -> str:
        var = m.group(1)
        if var not in os.environ:
            sys.exit(f"setup SQL references getenv('{var}') but {var} is not set")
        return sql_str(os.environ[var])

    return re.sub(r"getenv\('([A-Za-z0-9_]+)'\)", sub, sql)


def build_diff_call(args: argparse.Namespace) -> str:
    pks = [c.strip() for c in args.pk.split(",") if c.strip()]
    pk = sql_str(pks[0]) if len(pks) == 1 else "[" + ", ".join(map(sql_str, pks)) + "]"
    opts = [f"pk := {pk}"]
    if args.upcast:
        opts += ["require_matching_columns := false", "upcast_types := true"]
    if args.tolerance is not None:
        opts.append(f"numeric_tolerance := {args.tolerance}")
    if args.timestamp_precision:
        opts.append(f"timestamp_precision := {sql_str(args.timestamp_precision)}")
    if args.null_equals_empty:
        opts.append("null_equals_empty := true")
    if args.ignore:
        cols = [c.strip() for c in args.ignore.split(",") if c.strip()]
        opts.append("ignore := [" + ", ".join(map(sql_str, cols)) + "]")
    return f"$${args.left}$$, $${args.right}$$, " + ", ".join(opts)


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>duck_diff report</title>
<style>
  body { font: 14px/1.5 system-ui, sans-serif; margin: 2rem auto; max-width: 80rem; padding: 0 1rem; color: #1a1a1a; }
  .meta { color: #666; }
  .toolbar { display: flex; gap: .5rem; align-items: center; flex-wrap: wrap; margin: 1rem 0 .5rem; }
  .toolbar input { padding: .3rem .5rem; border: 1px solid #ccc; border-radius: 4px; min-width: 14rem; }
  .toolbar .count { color: #666; margin-left: auto; }
  .chip { border: 1px solid #ccc; border-radius: 999px; padding: .15rem .7rem; background: #fff; color: #999; cursor: pointer; }
  .chip.on.different  { background: #fff3cd; color: #1a1a1a; }
  .chip.on.left_only  { background: #f8d7da; color: #1a1a1a; }
  .chip.on.right_only { background: #cfe2ff; color: #1a1a1a; }
  .chip.on.identical  { background: #d1e7dd; color: #1a1a1a; }
  .tablewrap { overflow: auto; max-height: 75vh; border: 1px solid #d0d0d0; }
  table { border-collapse: collapse; font-variant-numeric: tabular-nums; width: max-content; }
  th, td { border: 1px solid #d0d0d0; padding: .3rem .55rem; text-align: left; white-space: nowrap; }
  th { background: #f4f4f4; cursor: pointer; user-select: none; position: sticky; top: 0; }
  td.different  { background: #fff3cd; }
  td.left_only  { background: #f8d7da; }
  td.right_only { background: #cfe2ff; }
  td.identical  { background: #d1e7dd; }
  .dd { display: flex; gap: .4rem; align-items: baseline; }
  .dd-col { font-weight: 600; }
  .dd-old { background: #f8d7da; padding: 0 .3rem; border-radius: 3px; }
  .dd-new { background: #d1e7dd; padding: 0 .3rem; border-radius: 3px; }
  #more { margin: .8rem 0; padding: .4rem 1rem; }
</style></head><body>
<h1>duck_diff report</h1>
<p class="meta" id="meta"></p>
<div class="toolbar" id="bar"><input type="search" id="q" placeholder="filter rows…"><span class="count" id="count"></span></div>
<div class="tablewrap"><table><thead id="head"></thead><tbody id="body"></tbody></table></div>
<button id="more" hidden>Show more</button>
<script id="data" type="application/json">__DATA__</script>
<script>
var payload = JSON.parse(document.getElementById('data').textContent);
var cols = payload.columns, rows = payload.rows;
var WINDOW = 2000, shown = WINDOW, sortCol = null, sortDir = 1;
var statuses = ['different', 'left_only', 'right_only', 'identical'];
var active = {}; statuses.forEach(function (s) { active[s] = true; });

document.getElementById('meta').textContent = payload.meta;
var head = document.getElementById('head'), body = document.getElementById('body');
var tr = document.createElement('tr');
cols.forEach(function (c, i) {
  var th = document.createElement('th'); th.textContent = c;
  th.onclick = function () {
    sortDir = (sortCol === i) ? -sortDir : 1; sortCol = i; render();
  };
  tr.appendChild(th);
});
head.appendChild(tr);

var bar = document.getElementById('bar'), q = document.getElementById('q');
statuses.forEach(function (s) {
  if (!rows.some(function (r) { return r[payload.statusIdx] === s; })) return;
  var chip = document.createElement('button');
  chip.className = 'chip on ' + s; chip.textContent = s;
  chip.onclick = function () { active[s] = !active[s]; chip.classList.toggle('on'); shown = WINDOW; render(); };
  bar.insertBefore(chip, document.getElementById('count'));
});

function fmt(v) { return v === null ? 'NULL' : String(v); }
function matches(r, needle) {
  if (active[r[payload.statusIdx]] === false) return false;
  if (!needle) return true;
  for (var i = 0; i < r.length; i++)
    if (fmt(r[i]).toLowerCase().indexOf(needle) !== -1) return true;
  return false;
}
function render() {
  var needle = q.value.toLowerCase();
  var pass = rows.filter(function (r) { return matches(r, needle); });
  if (sortCol !== null) pass.sort(function (a, b) {
    var x = a[sortCol], y = b[sortCol];
    if (x === null) return 1; if (y === null) return -1;
    var cmp = (typeof x === 'number' && typeof y === 'number') ? x - y : String(x).localeCompare(String(y));
    return sortDir * cmp;
  });
  body.textContent = '';
  var frag = document.createDocumentFragment();
  pass.slice(0, shown).forEach(function (r) {
    var trow = document.createElement('tr');
    r.forEach(function (v, i) {
      var td = document.createElement('td');
      var s = fmt(v);
      if (statuses.indexOf(s) !== -1) td.className = s;
      if (cols[i] === 'diff_data' && v && typeof v === 'object') {
        Object.keys(v).forEach(function (k) {
          var line = document.createElement('div'); line.className = 'dd';
          [['dd-col', k], ['dd-old', fmt(v[k].left)], ['', '→'], ['dd-new', fmt(v[k].right)]].forEach(function (p) {
            var sp = document.createElement('span'); sp.className = p[0]; sp.textContent = p[1]; line.appendChild(sp);
          });
          td.appendChild(line);
        });
      } else td.textContent = s;
      trow.appendChild(td);
    });
    frag.appendChild(trow);
  });
  body.appendChild(frag);
  document.getElementById('count').textContent =
    Math.min(shown, pass.length) + ' shown / ' + pass.length + ' matching / ' + rows.length + ' total';
  document.getElementById('more').hidden = pass.length <= shown;
}
q.oninput = function () { shown = WINDOW; render(); };
document.getElementById('more').onclick = function () { shown += WINDOW; render(); };
render();
</script></body></html>
"""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--left", required=True, help="left relation, e.g. \"FROM read_csv('a.csv')\"")
    ap.add_argument("--right", required=True, help="right relation")
    ap.add_argument("--pk", required=True, help="primary key column(s), comma-separated")
    ap.add_argument("--setup", type=Path, help="SQL file run first (ATTACH, secrets, INSTALL/LOAD, macros)")
    ap.add_argument("--ignore", help="columns to exclude, comma-separated")
    ap.add_argument("--upcast", action="store_true",
                    help="type promotion for cross-system diffs (require_matching_columns := false, upcast_types := true)")
    ap.add_argument("--tolerance", type=float, help="numeric_tolerance: |left-right| <= t counts as identical")
    ap.add_argument("--timestamp-precision", choices=["millisecond", "second", "minute", "hour", "day"],
                    help="truncate timestamps before comparing")
    ap.add_argument("--null-equals-empty", action="store_true", help="treat NULL and '' as equal for VARCHAR")
    ap.add_argument("--out", type=Path, default=Path("diff_report.html"))
    ap.add_argument("--serve", action="store_true", help="serve the report over HTTP instead of opening the file")
    ap.add_argument("--port", type=int, default=8437)
    args = ap.parse_args()

    con = duckdb.connect(config={"allow_unsigned_extensions": True})
    duck_diff = os.environ.get("DUCK_DIFF")  # optional: path to a locally built extension
    if duck_diff:
        con.execute(f"LOAD {sql_str(duck_diff)}")
    else:
        con.execute("INSTALL duck_diff FROM community")
        con.execute("LOAD duck_diff")

    if args.setup:
        con.execute(rewrite_getenv(args.setup.read_text()))

    call = build_diff_call(args)

    cur = con.execute(f"FROM table_diff_summary({call})")
    cols = [d[0] for d in cur.description]
    for name, value in zip(cols, cur.fetchone()):
        print(f"{name:>16}  {value}")

    # One JSON object per row keeps types readable and diff_data structured.
    rows_json = con.execute(
        f"SELECT to_json(t)::VARCHAR FROM (FROM table_diff({call})) t"
    ).fetchall()
    rows_objs = [json.loads(r[0]) for r in rows_json]
    columns = list(rows_objs[0].keys()) if rows_objs else ["diff_status"]
    data = {
        "columns": columns,
        "statusIdx": columns.index("diff_status") if "diff_status" in columns else 0,
        "rows": [[r.get(c) for c in columns] for r in rows_objs],
        "meta": f"left: {args.left}  ·  right: {args.right}  ·  pk: {args.pk}",
    }
    html = PAGE.replace("__DATA__", json.dumps(data).replace("</", "<\\/"))
    args.out.write_text(html)
    print(f"wrote {args.out} ({len(rows_objs)} rows)")

    if args.serve:
        os.chdir(args.out.resolve().parent)
        url = f"http://127.0.0.1:{args.port}/{args.out.name}"
        print(f"serving {url}  (Ctrl-C to stop)")
        webbrowser.open(url)
        http.server.ThreadingHTTPServer(
            ("127.0.0.1", args.port), http.server.SimpleHTTPRequestHandler
        ).serve_forever()
    else:
        webbrowser.open(args.out.resolve().as_uri())


if __name__ == "__main__":
    main()
