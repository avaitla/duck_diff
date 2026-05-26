#define DUCKDB_EXTENSION_MAIN

#include "duck_diff_extension.hpp"
#include "duckdb.hpp"
#include "duckdb/common/exception.hpp"

namespace duckdb {

static void LoadInternal(ExtensionLoader &loader) {
	// Functions are registered here in part b:
	//   table_diff(left, right, key := 'id')
	//   table_diff_summary(left, right, key := 'id')
	//   tables_equal(left, right, key := 'id')
}

void DuckDiffExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}

std::string DuckDiffExtension::Name() {
	return "duck_diff";
}

std::string DuckDiffExtension::Version() const {
#ifdef EXT_VERSION_DUCK_DIFF
	return EXT_VERSION_DUCK_DIFF;
#else
	return "";
#endif
}

} // namespace duckdb

extern "C" {

DUCKDB_CPP_EXTENSION_ENTRY(duck_diff, loader) {
	duckdb::LoadInternal(loader);
}
}
