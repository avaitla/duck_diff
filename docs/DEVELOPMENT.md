# Development — building duck_diff from source

The repo vendors DuckDB and the build tooling as submodules, so a clone +
`make` produces a DuckDB shell with `duck_diff` preloaded:

```sh
git clone --recurse-submodules https://github.com/avaitla/duck_diff
cd duck_diff
GEN=ninja make            # first build compiles DuckDB; needs cmake + ninja
./build/release/duckdb    # this shell already has duck_diff loaded

build/release/test/unittest "test/sql/*"   # run the SQL test suite
```

(Cloned without submodules? `git submodule update --init --recursive`.)

The extension generates SQL using `json_object` / `json_merge_patch`, so the
bundled `json` extension is required (built in automatically for tests).

## Using a local build in another DuckDB

The build also emits a loadable binary at
`build/release/extension/duck_diff/duck_diff.duckdb_extension`. It's locally
built (unsigned), so load it with unsigned extensions enabled:

```sh
duckdb -unsigned
```
```sql
LOAD 'build/release/extension/duck_diff/duck_diff.duckdb_extension';
SELECT * FROM table_diff('FROM a', 'FROM b', pk := 'id');
```

The demo scripts pick up a local build via the `DUCK_DIFF` env var
(`DUCK_DIFF=/path/to/duck_diff.duckdb_extension ./demo/run.sh …`).

## Installing without building

- `INSTALL duck_diff FROM community; LOAD duck_diff;` on stock DuckDB — the
  extension is published on the
  [DuckDB community repository](https://duckdb.org/community_extensions/extensions/duck_diff).
- Signed per-platform binaries are attached to each
  [GitHub Release](https://github.com/avaitla/duck_diff/releases) — download
  as `duck_diff.duckdb_extension` and `LOAD` it under `-unsigned` (they are
  signed with a third-party key, which stock DuckDB doesn't trust for
  flag-free loading). Details and signature verification:
  [DISTRIBUTION.md](DISTRIBUTION.md).
