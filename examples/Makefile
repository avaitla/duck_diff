# Run the example sqllogictest (.test) files against a built duck_diff.
#
# sqllogictest is DuckDB's standard test format; the `unittest` binary that
# runs it is produced by the duck_diff build. Build once from the repo root
# (GEN=ninja make), then from this directory:
#
#   make test
#
# `--test-dir .` points the runner at this directory, so it discovers the
# .test files under ./test/. Override the binary if it lives elsewhere:
#
#   make test UNITTEST=/path/to/build/release/test/unittest

UNITTEST ?= ../build/release/test/unittest

.PHONY: test
test:
	@test -x "$(UNITTEST)" || { \
	  echo "unittest binary not found at '$(UNITTEST)'"; \
	  echo "build it first:  (cd .. && GEN=ninja make)"; \
	  exit 1; }
	"$(UNITTEST)" --test-dir . "test/*"
