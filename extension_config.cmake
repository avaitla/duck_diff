# This file is included by DuckDB's build system. It specifies which extension to load

# Extension from this repo
duckdb_extension_load(duck_diff
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
)

# duck_diff generates SQL that uses json_object / json_merge_patch, so the json
# extension must be available. Build it in so tests can `require json`.
duckdb_extension_load(json)
