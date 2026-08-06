-- html_report(sql): render any query's result — typically a table_diff — as a
-- complete, styled, interactive HTML document, straight from the duckdb shell.
--
-- Usage (inside `duckdb -unsigned`):
--
--   LOAD duck_diff;
--   .read html_report.sql
--   COPY (FROM html_report($$
--       SELECT * FROM table_diff('FROM primary_db.orders', 'FROM replica_db.orders', pk := 'id')
--   $$)) TO 'diff.html' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
--   .shell open diff.html
--
-- (.shell runs a host command: use `open` on macOS, `xdg-open` on Linux.)
-- The COPY options write the single VARCHAR cell verbatim, so diff.html is a
-- normal standalone web page: click-to-sort headers, a search box, clickable
-- diff_status filter chips — same features as report.sh, no network needed.

CREATE OR REPLACE MACRO html_escape(s) AS
    replace(replace(replace(s, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

CREATE OR REPLACE MACRO html_report(sql) AS TABLE
WITH _rows AS (
    SELECT to_json(q) AS j, row_number() OVER () AS rn
    FROM query(sql) q
),
_body AS (
    SELECT
        (SELECT '<tr>' || array_to_string(
                    ['<th>' || html_escape(k) || '</th>' for k in json_keys(j)], '')
                || '</tr>'
         FROM _rows WHERE rn = 1) AS header,
        string_agg(
            '<tr>' || array_to_string(
                [CASE WHEN (j ->> k) IN ('different', 'left_only', 'right_only', 'identical')
                      THEN '<td class="' || (j ->> k) || '">'
                      ELSE '<td>'
                 END || html_escape(coalesce(j ->> k, 'NULL')) || '</td>'
                 for k in json_keys(j)], '')
            || '</tr>',
            '' ORDER BY rn) AS trs
    FROM _rows
)
SELECT $css$<!doctype html>
<html><head><meta charset="utf-8"><title>duck_diff report</title>
<style>
  body { font: 14px/1.5 system-ui, sans-serif; margin: 2rem auto; max-width: 76rem; padding: 0 1rem; color: #1a1a1a; }
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
</style></head><body>
<h1>duck_diff report</h1>
<table>$css$
       || coalesce(header, '') || coalesce(trs, '')
       || $js$</table>
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
</body></html>$js$ AS html
FROM _body;
