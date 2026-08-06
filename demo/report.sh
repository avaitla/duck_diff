#!/usr/bin/env bash
# Render a demo's output as a standalone, interactive HTML page:
#
#   export PGPASSWORD=…      # same env vars the demo reads via run.sh
#   ./report.sh postgres_vs_clickhouse.sql              # -> postgres_vs_clickhouse.html
#   ./report.sh postgres_vs_clickhouse.sql /tmp/out.html
#
# The page opens in your default browser when done (macOS `open` /
# Linux `xdg-open`) and is a plain static file afterwards — reopen it with
# `open <name>.html`, double-click it, or attach it to a ticket. Each query in
# the demo becomes its own table with click-to-sort headers, a search box, and
# clickable diff_status filter chips; everything is inlined, no network needed.
# An optional `.env` in this directory is sourced like run.sh does.
set -euo pipefail
cd "$(dirname "$0")"

[[ ($# -eq 1 || $# -eq 2) && -f ${1:-} ]] || { echo "usage: ./report.sh <demo.sql> [out.html]" >&2; exit 1; }
OUT=${2:-$(basename "${1%.sql}").html}

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
fi

DUCKDB=${DUCKDB:-duckdb}
DUCK_DIFF=${DUCK_DIFF:-duck_diff}
TITLE=$(basename "$1")
GENERATED=$(date)

{
  printf '<!doctype html>\n<html><head><meta charset="utf-8">\n<title>duck_diff — %s</title>\n' "$TITLE"
  cat <<'HTML'
<style>
  body { font: 14px/1.5 system-ui, sans-serif; margin: 2rem auto; max-width: 76rem; padding: 0 1rem; color: #1a1a1a; }
  h1 { font-size: 1.3rem; }
  .meta { color: #666; }
  .toolbar { display: flex; gap: .5rem; align-items: center; flex-wrap: wrap; margin: 1.5rem 0 0; }
  .toolbar input { padding: .3rem .5rem; border: 1px solid #ccc; border-radius: 4px; min-width: 14rem; }
  .toolbar .count { color: #666; margin-left: auto; }
  .chip { border: 1px solid #ccc; border-radius: 999px; padding: .15rem .7rem; background: #fff; color: #999; cursor: pointer; }
  .chip.on.different  { background: #fff3cd; color: #1a1a1a; }
  .chip.on.left_only  { background: #f8d7da; color: #1a1a1a; }
  .chip.on.right_only { background: #cfe2ff; color: #1a1a1a; }
  .chip.on.identical  { background: #d1e7dd; color: #1a1a1a; }
  .tablewrap { overflow-x: auto; margin: .5rem 0 2rem; }
  table { border-collapse: collapse; font-variant-numeric: tabular-nums; }
  th, td { border: 1px solid #d0d0d0; padding: .35rem .6rem; text-align: left; white-space: nowrap; }
  th { background: #f4f4f4; cursor: pointer; user-select: none; position: sticky; top: 0; }
  th.sorted::after { content: " " attr(data-arrow); }
  td.different  { background: #fff3cd; }
  td.left_only  { background: #f8d7da; }
  td.right_only { background: #cfe2ff; }
  td.identical  { background: #d1e7dd; }
  td .dd { display: flex; gap: .45rem; align-items: baseline; }
  td .dd + .dd { margin-top: .15rem; }
  .dd-col { font-weight: 600; }
  .dd-old { background: #f8d7da; padding: 0 .3rem; border-radius: 3px; }
  .dd-new { background: #d1e7dd; padding: 0 .3rem; border-radius: 3px; }
  .dd-arrow { color: #666; }
  td details summary { cursor: pointer; color: #666; }
  td details pre { margin: .3rem 0 0; text-align: left; }
</style>
</head><body>
HTML
  printf '<h1>duck_diff report — %s</h1>\n' "$TITLE"
  printf '<p class="meta">Generated %s · one table per query · click a header to sort, type to filter, toggle the status chips.</p>\n' "$GENERATED"

  # `.mode html` emits bare rows; a header row (<tr><th>…) marks the start of
  # each query's output, so wrap every query in its own <table>.
  { printf "LOAD '%s';\n.mode html\n" "$DUCK_DIFF"; cat "$1"; } \
    | "$DUCKDB" -unsigned \
    | awk '
        # drop the one-cell "Success" tables emitted by CREATE SECRET etc.
        /^<tr><th>Success<\/th>$/ { if (open) { print "</table>"; open = 0 } skip = 1; next }
        /^<tr><th>/ { if (open) print "</table>"; print "<table>"; open = 1; skip = 0 }
        skip { next }
        { print }
        END { if (open) print "</table>" }
      ' \
    | sed -E 's#<td>(different|left_only|right_only|identical)</td>#<td class="\1">\1</td>#g'

  cat <<'HTML'
<script>
document.querySelectorAll('table').forEach(function (tbl) {
  var wrap = document.createElement('div');
  wrap.className = 'tablewrap';
  tbl.parentNode.insertBefore(wrap, tbl);
  wrap.appendChild(tbl);

  var rows = Array.prototype.filter.call(
    tbl.querySelectorAll('tr'),
    function (r) { return r.querySelector('td'); }
  );
  // Unroll JSON cells: diff_data's {"col":{"left":…,"right":…}} becomes one
  // "col: old → new" line per changed column; other JSON gets a collapsible
  // pretty-printed view.
  rows.forEach(function (r) {
    Array.prototype.forEach.call(r.querySelectorAll('td'), function (td) {
      var t = td.textContent.trim();
      if (t.charAt(0) !== '{') return;
      var obj;
      try { obj = JSON.parse(t); } catch (e) { return; }
      if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return;
      var keys = Object.keys(obj);
      var isDiff = keys.length && keys.every(function (k) {
        var v = obj[k];
        return v && typeof v === 'object' && 'left' in v && 'right' in v;
      });
      var fmt = function (v) {
        if (v === null) return 'NULL';
        return typeof v === 'object' ? JSON.stringify(v) : String(v);
      };
      td.textContent = '';
      if (isDiff) {
        keys.forEach(function (k) {
          var line = document.createElement('div');
          line.className = 'dd';
          [['dd-col', k], ['dd-old', fmt(obj[k].left)], ['dd-arrow', '→'], ['dd-new', fmt(obj[k].right)]]
            .forEach(function (p) {
              var s = document.createElement('span');
              s.className = p[0];
              s.textContent = p[1];
              line.appendChild(s);
            });
          td.appendChild(line);
        });
      } else {
        var det = document.createElement('details');
        var sum = document.createElement('summary');
        sum.textContent = t.length > 40 ? t.slice(0, 40) + '…' : t;
        var pre = document.createElement('pre');
        pre.textContent = JSON.stringify(obj, null, 2);
        det.appendChild(sum);
        det.appendChild(pre);
        td.appendChild(det);
      }
    });
  });

  var statuses = ['different', 'left_only', 'right_only', 'identical'];
  var present = statuses.filter(function (s) { return tbl.querySelector('td.' + s); });
  var active = {};
  present.forEach(function (s) { active[s] = true; });

  var bar = document.createElement('div');
  bar.className = 'toolbar';
  var search = document.createElement('input');
  search.type = 'search';
  search.placeholder = 'filter rows…';
  bar.appendChild(search);
  var count = document.createElement('span');
  count.className = 'count';

  function apply() {
    var q = search.value.toLowerCase();
    var shown = 0;
    rows.forEach(function (r) {
      var ok = !q || r.textContent.toLowerCase().indexOf(q) !== -1;
      if (ok && present.length) {
        var s = present.find(function (p) { return r.querySelector('td.' + p); });
        if (s) ok = active[s];
      }
      r.style.display = ok ? '' : 'none';
      if (ok) shown++;
    });
    count.textContent = shown + ' / ' + rows.length + ' rows';
  }

  present.forEach(function (s) {
    var chip = document.createElement('button');
    chip.className = 'chip on ' + s;
    chip.textContent = s;
    chip.onclick = function () {
      active[s] = !active[s];
      chip.classList.toggle('on');
      apply();
    };
    bar.appendChild(chip);
  });
  bar.appendChild(count);
  wrap.parentNode.insertBefore(bar, wrap);
  search.oninput = apply;

  var ths = tbl.querySelectorAll('th');
  Array.prototype.forEach.call(ths, function (th, i) {
    th.onclick = function () {
      var dir = th.dataset.dir === 'asc' ? 'desc' : 'asc';
      Array.prototype.forEach.call(ths, function (h) {
        delete h.dataset.dir;
        h.classList.remove('sorted');
      });
      th.dataset.dir = dir;
      th.dataset.arrow = dir === 'asc' ? '▲' : '▼';
      th.classList.add('sorted');
      var parent = rows[0].parentNode;
      rows.sort(function (a, b) {
        var x = a.children[i] ? a.children[i].textContent : '';
        var y = b.children[i] ? b.children[i].textContent : '';
        var nx = parseFloat(x), ny = parseFloat(y);
        var cmp = (!isNaN(nx) && !isNaN(ny)) ? nx - ny : x.localeCompare(y);
        return dir === 'asc' ? cmp : -cmp;
      });
      rows.forEach(function (r) { parent.appendChild(r); });
    };
  });

  apply();
});
</script>
</body></html>
HTML
} > "$OUT"

echo "wrote $OUT"
if command -v open >/dev/null 2>&1; then open "$OUT"
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$OUT"
fi
