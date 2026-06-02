#!/usr/bin/env bash
#
# Minimal sqllogictest runner built on the duckdb CLI.
#
# Lets you unit-test your own DuckDB SQL in the standard sqllogictest format
# with nothing installed but the `duckdb` binary — no source build, no
# `unittest` binary, no extension required. It covers the common subset of the
# format (see https://duckdb.org/dev/sqllogictest/intro), which is enough for
# most project test suites.
#
# Supported records (a blank line ends each record):
#   statement ok        run the SQL; FAIL if it errors
#   statement error     run the SQL; FAIL if it succeeds
#   query <types>       run the SQL; compare its tab-separated output to the
#                       lines following the `----` separator
#   # comment           ignored
#   require / mode / …  ignored (kept so files stay portable to real unittest)
#
# Tables persist across records within a file; each file gets a fresh database.
#
# Usage:  run_sqllogictest.sh [FILE ...]      (defaults to tests/*.test)
#         DUCKDB=/path/to/duckdb run_sqllogictest.sh ...

set -u
DUCKDB="${DUCKDB:-duckdb}"
TAB="$(printf '\t')"

# `-unsigned` is harmless when no extension is used; it lets your tests
# `LOAD duck_diff;` (or any installed extension) if you want richer assertions.

# Run a statement; output (incl. errors) on stdout, exit code preserved.
slt_stmt() { "$DUCKDB" "$1" -unsigned -batch -init /dev/null -c "$2" 2>&1; }

# Run a query; deterministic output: no header, tab-separated, NULL -> "NULL".
slt_query() {
	"$DUCKDB" "$1" -unsigned -batch -init /dev/null -noheader -list \
		-separator "$TAB" -cmd ".nullvalue NULL" -c "$2" 2>&1
}

run_file() {
	file="$1"
	db="$(mktemp -u)".db
	rm -f "$db"

	# Slurp the file into an array (bash 3.2 compatible — no mapfile).
	lines=()
	while IFS= read -r ln || [ -n "$ln" ]; do lines+=("$ln"); done <"$file"
	n=${#lines[@]}

	# Each record runs as its own `duckdb -c`, so persistent tables carry over
	# (they live in the db file) but session state does not. Replay extension
	# loads before every record so `LOAD`/`INSTALL` persist across the file.
	preamble=""
	k=0
	while [ "$k" -lt "$n" ]; do
		case "${lines[$k]}" in
		[Ll][Oo][Aa][Dd]\ * | [Ii][Nn][Ss][Tt][Aa][Ll][Ll]\ *)
			preamble="$preamble${lines[$k]}
"
			;;
		esac
		k=$((k + 1))
	done

	fails=0
	checks=0
	i=0
	while [ "$i" -lt "$n" ]; do
		ln="${lines[$i]}"
		case "$ln" in
		'' | '#'*)
			i=$((i + 1))
			;;
		'require'* | 'mode'* | 'halt'* | 'hash-threshold'* | 'skipif'* | 'onlyif'*)
			i=$((i + 1))
			;;
		'statement ok' | 'statement error')
			kind="$ln"
			i=$((i + 1))
			sql=""
			while [ "$i" -lt "$n" ] && [ -n "${lines[$i]}" ] && [ "${lines[$i]#\#}" = "${lines[$i]}" ]; do
				sql="$sql${lines[$i]}
"
				i=$((i + 1))
			done
			checks=$((checks + 1))
			out="$(slt_stmt "$db" "$preamble$sql")"
			rc=$?
			if [ "$kind" = "statement ok" ] && [ "$rc" -ne 0 ]; then
				printf 'FAIL %s: statement expected to succeed:\n%s\n%s\n' "$file" "$sql" "$out"
				fails=$((fails + 1))
			elif [ "$kind" = "statement error" ] && [ "$rc" -eq 0 ]; then
				printf 'FAIL %s: statement expected to error:\n%s\n' "$file" "$sql"
				fails=$((fails + 1))
			fi
			;;
		'query'*)
			i=$((i + 1))
			sql=""
			while [ "$i" -lt "$n" ] && [ "${lines[$i]}" != "----" ]; do
				sql="$sql${lines[$i]}
"
				i=$((i + 1))
			done
			i=$((i + 1)) # skip the ---- separator
			expected=""
			while [ "$i" -lt "$n" ] && [ -n "${lines[$i]}" ] && [ "${lines[$i]#\#}" = "${lines[$i]}" ]; do
				expected="$expected${lines[$i]}
"
				i=$((i + 1))
			done
			checks=$((checks + 1))
			out="$(slt_query "$db" "$preamble$sql")"
			rc=$?
			exp="${expected%$'\n'}"
			if [ "$rc" -ne 0 ]; then
				printf 'FAIL %s: query errored:\n%s\n%s\n' "$file" "$sql" "$out"
				fails=$((fails + 1))
			elif [ "$out" != "$exp" ]; then
				printf 'FAIL %s: result mismatch for:\n%s' "$file" "$sql"
				printf '  expected:\n%s\n' "$exp" | sed 's/^/    /'
				printf '  actual:\n%s\n' "$out" | sed 's/^/    /'
				fails=$((fails + 1))
			fi
			;;
		*)
			i=$((i + 1))
			;;
		esac
	done

	rm -f "$db"
	if [ "$fails" -eq 0 ]; then
		printf 'ok   %s (%d checks)\n' "$file" "$checks"
		return 0
	fi
	printf 'FAIL %s (%d/%d checks failed)\n' "$file" "$fails" "$checks"
	return 1
}

if ! command -v "$DUCKDB" >/dev/null 2>&1; then
	echo "duckdb not found on PATH (set DUCKDB=/path/to/duckdb)" >&2
	exit 127
fi

if [ "$#" -eq 0 ]; then
	set -- tests/*.test
fi

failed=0
ran=0
for f in "$@"; do
	[ -f "$f" ] || continue
	ran=$((ran + 1))
	run_file "$f" || failed=$((failed + 1))
done

if [ "$ran" -eq 0 ]; then
	echo "no .test files found" >&2
	exit 1
fi
if [ "$failed" -ne 0 ]; then
	printf '\n%d file(s) failed\n' "$failed" >&2
	exit 1
fi
echo
echo "all $ran file(s) passed"
