#!/usr/bin/env bash
# Run one demo through the duckdb CLI:
#
#   export PGPASSWORD=…      # each demo's header lists the vars it reads
#   ./run.sh postgres_vs_snowflake.sql
#
# Credentials come from the environment: exported env vars -> getenv() in the
# SQL -> DuckDB's secret manager. Nothing is inlined in the SQL. As an
# optional convenience, a `.env` file in this directory (gitignored — see
# .env.example) is sourced if present; its values win over already-exported
# variables.
#
# Overrides:
#   DUCKDB=/path/to/duckdb                          which CLI to use
#   DUCK_DIFF=/path/to/duck_diff.duckdb_extension   a downloaded release binary
#                                                   (default: the installed
#                                                   extension name `duck_diff`)
set -euo pipefail
cd "$(dirname "$0")"

[[ $# -eq 1 && -f ${1:-} ]] || { echo "usage: ./run.sh <demo.sql>" >&2; exit 1; }

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
fi

DUCKDB=${DUCKDB:-duckdb}
DUCK_DIFF=${DUCK_DIFF:-duck_diff}

# -unsigned because duck_diff release binaries are signed with a third-party
# key (see ../docs/DISTRIBUTION.md).
{ printf "LOAD '%s';\n" "$DUCK_DIFF"; cat "$1"; } | "$DUCKDB" -unsigned
