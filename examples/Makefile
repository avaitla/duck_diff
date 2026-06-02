# Unit-test your own DuckDB SQL in the sqllogictest format — with nothing
# installed but the `duckdb` CLI. Copy this directory into your project.
#
#   make setup    # check that duckdb is available
#   make test     # run every tests/*.test file
#
# No source build, no `unittest` binary, no extension required: tests/*.test
# are run by ./run_sqllogictest.sh, a small runner that drives the duckdb CLI.
# Use a different duckdb with:  make test DUCKDB=/path/to/duckdb

# Absolute path to this Makefile's directory, so the invoking cwd doesn't
# matter (e.g. `make -C examples test` from a parent project).
HERE   := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
DUCKDB ?= duckdb

.PHONY: setup test
setup:
	@command -v $(DUCKDB) >/dev/null 2>&1 || { \
	  echo "duckdb not found on PATH."; \
	  echo "install it from https://duckdb.org/docs/installation/"; \
	  echo "(or run with an explicit path: make test DUCKDB=/path/to/duckdb)"; \
	  exit 1; }
	@echo "duckdb: $$($(DUCKDB) --version)"
	@echo "ready — run 'make test'"

test:
	@cd "$(HERE)" && DUCKDB="$(DUCKDB)" bash run_sqllogictest.sh tests/*.test
