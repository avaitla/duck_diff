#define DUCKDB_EXTENSION_MAIN

#include "duck_diff_extension.hpp"
#include "duckdb.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/common/case_insensitive_map.hpp"
#include "duckdb/function/table_function.hpp"
#include "duckdb/parser/parser.hpp"
#include "duckdb/parser/statement/select_statement.hpp"
#include "duckdb/parser/tableref/subqueryref.hpp"
#include "duckdb/planner/binder.hpp"
#include "duckdb/planner/bound_statement.hpp"
#include "duckdb/catalog/default/default_functions.hpp"
#include "duckdb/parser/parsed_data/create_macro_info.hpp"

namespace duckdb {

namespace {

//===--------------------------------------------------------------------===//
// SQL-text helpers
//===--------------------------------------------------------------------===//

// Quote an identifier for use in generated SQL: "foo" / escapes embedded ".
string QuoteIdent(const string &id) {
	string out = "\"";
	for (char c : id) {
		if (c == '"') {
			out += "\"\"";
		} else {
			out += c;
		}
	}
	out += "\"";
	return out;
}

// Quote a string literal for use in generated SQL: 'foo' / escapes embedded '.
string QuoteLiteral(const string &s) {
	string out = "'";
	for (char c : s) {
		if (c == '\'') {
			out += "''";
		} else {
			out += c;
		}
	}
	out += "'";
	return out;
}

// Flatten a named-parameter Value into a list of strings. Accepts a single
// VARCHAR (-> one element) or a LIST (-> its non-null elements). NULL -> empty.
vector<string> ValueToStringList(const Value &v) {
	vector<string> result;
	if (v.IsNull()) {
		return result;
	}
	if (v.type().id() == LogicalTypeId::LIST) {
		for (auto &child : ListValue::GetChildren(v)) {
			if (!child.IsNull()) {
				result.push_back(child.ToString());
			}
		}
	} else {
		result.push_back(v.ToString());
	}
	return result;
}

//===--------------------------------------------------------------------===//
// Schema introspection
//===--------------------------------------------------------------------===//

struct RelationSchema {
	vector<string> names;
	vector<LogicalType> types;
};

// Resolve the column names and types of an arbitrary FROM-expression (table
// name, table function, or parenthesized subquery) by binding it. No data is
// read and no temporary objects are created.
RelationSchema InspectRelation(ClientContext &context, optional_ptr<Binder> parent, const string &relation,
                               const char *side) {
	string sql = "SELECT * FROM " + relation;
	Parser parser(context.GetParserOptions());
	try {
		parser.ParseQuery(sql);
	} catch (const std::exception &e) {
		throw BinderException("table_diff: could not parse the %s relation argument (%s): %s", side, relation,
		                      e.what());
	}
	if (parser.statements.size() != 1 || parser.statements[0]->type != StatementType::SELECT_STATEMENT) {
		throw BinderException("table_diff: the %s argument must be a table name, table function, or parenthesized "
		                      "subquery",
		                      side);
	}
	auto binder = Binder::CreateBinder(context, parent);
	RelationSchema schema;
	try {
		auto bound = binder->Bind(*parser.statements[0]);
		schema.names = bound.names;
		schema.types = bound.types;
	} catch (const std::exception &e) {
		throw BinderException("table_diff: could not resolve the %s relation (%s): %s", side, relation, e.what());
	}
	return schema;
}

//===--------------------------------------------------------------------===//
// Resolved plan: parsed args + reconciled schema
//===--------------------------------------------------------------------===//

struct DiffPlan {
	string left;
	string right;
	vector<string> key_cols;     // canonical (left) names, in order
	vector<string> value_cols;   // compared non-key columns, in order
	vector<string> context_cols; // pulled from both sides into left_context / right_context
	bool has_context = false;
	bool wide = false; // expand columns (a_left/a_right/a_diff) instead of JSON diff_data
	string prefix = "diff_";
};

// Look up a named parameter, returning nullptr if absent.
const Value *FindParam(TableFunctionBindInput &input, const string &name) {
	auto it = input.named_parameters.find(name);
	if (it == input.named_parameters.end() || it->second.IsNull()) {
		return nullptr;
	}
	return &it->second;
}

// Parse arguments, introspect both relations, and reconcile the schema into the
// set of columns to compare / pull through. Throws clean BinderExceptions for
// strict-mode mismatches and missing keys.
DiffPlan ResolvePlan(ClientContext &context, TableFunctionBindInput &input) {
	if (input.inputs.size() < 2) {
		throw BinderException("table_diff: requires two relation arguments (left, right)");
	}
	DiffPlan plan;
	plan.left = input.inputs[0].ToString();
	plan.right = input.inputs[1].ToString();

	// pk (required) + additional_pk
	auto pk_it = input.named_parameters.find("pk");
	if (pk_it == input.named_parameters.end() || pk_it->second.IsNull()) {
		throw BinderException("table_diff: the 'pk' parameter is required, e.g. pk := 'id' or pk := ['a','b']");
	}
	for (auto &c : ValueToStringList(pk_it->second)) {
		plan.key_cols.push_back(c);
	}
	if (auto *apk = FindParam(input, "additional_pk")) {
		for (auto &c : ValueToStringList(*apk)) {
			plan.key_cols.push_back(c);
		}
	}
	if (plan.key_cols.empty()) {
		throw BinderException("table_diff: the 'pk' parameter must name at least one column");
	}

	// compare mode
	bool strict = true;
	if (auto *cmp = FindParam(input, "compare")) {
		auto mode = StringUtil::Lower(cmp->ToString());
		if (mode == "intersect") {
			strict = false;
		} else if (mode != "strict") {
			throw BinderException("table_diff: 'compare' must be 'strict' or 'intersect', got '%s'", mode);
		}
	}

	// columns / ignore / context lists
	vector<string> only_columns, ignore_columns;
	if (auto *cols = FindParam(input, "columns")) {
		only_columns = ValueToStringList(*cols);
	}
	if (auto *ign = FindParam(input, "ignore")) {
		ignore_columns = ValueToStringList(*ign);
	}
	if (auto *ctx = FindParam(input, "context")) {
		plan.context_cols = ValueToStringList(*ctx);
		plan.has_context = true;
	}
	if (auto *pre = FindParam(input, "prefix")) {
		plan.prefix = pre->ToString();
	}
	if (auto *w = FindParam(input, "wide")) {
		plan.wide = BooleanValue::Get(*w);
	}

	// introspect both sides
	auto ls = InspectRelation(context, input.binder, plan.left, "left");
	auto rs = InspectRelation(context, input.binder, plan.right, "right");
	case_insensitive_map_t<LogicalType> lmap, rmap;
	for (idx_t i = 0; i < ls.names.size(); i++) {
		lmap[ls.names[i]] = ls.types[i];
	}
	for (idx_t i = 0; i < rs.names.size(); i++) {
		rmap[rs.names[i]] = rs.types[i];
	}

	case_insensitive_set_t key_set;
	for (auto &k : plan.key_cols) {
		key_set.insert(k);
	}
	case_insensitive_set_t ignore_set;
	for (auto &c : ignore_columns) {
		ignore_set.insert(c);
	}

	// keys must exist (and match types) on both sides
	for (auto &k : plan.key_cols) {
		auto l_it = lmap.find(k);
		auto r_it = rmap.find(k);
		if (l_it == lmap.end() || r_it == rmap.end()) {
			throw BinderException("table_diff: key column \"%s\" does not exist in both relations", k);
		}
		if (l_it->second != r_it->second) {
			throw BinderException("table_diff: key column \"%s\" has type %s on the left but %s on the right", k,
			                      l_it->second.ToString(), r_it->second.ToString());
		}
	}
	// canonicalize key names to the left relation's casing
	for (auto &k : plan.key_cols) {
		k = lmap.find(k)->first;
	}

	// candidate compared columns (left order, or the explicit columns list)
	vector<string> candidates;
	if (!only_columns.empty()) {
		candidates = only_columns;
	} else {
		for (auto &name : ls.names) {
			candidates.push_back(name);
		}
	}
	for (auto &c : candidates) {
		if (key_set.find(c) != key_set.end() || ignore_set.find(c) != ignore_set.end()) {
			continue;
		}
		auto l_it = lmap.find(c);
		auto r_it = rmap.find(c);
		if (l_it == lmap.end()) {
			if (strict) {
				throw BinderException("table_diff: column \"%s\" does not exist in the left relation", c);
			}
			continue;
		}
		if (r_it == rmap.end()) {
			if (strict) {
				throw BinderException("table_diff: column \"%s\" exists on the left but not the right; column sets "
				                      "differ (use compare := 'intersect' to compare only common columns)",
				                      c);
			}
			continue;
		}
		if (l_it->second != r_it->second) {
			if (strict) {
				throw BinderException("table_diff: column \"%s\" has type %s on the left but %s on the right", c,
				                      l_it->second.ToString(), r_it->second.ToString());
			}
			continue; // intersect: drop type-mismatched columns
		}
		plan.value_cols.push_back(l_it->first);
	}
	// strict: also reject columns present only on the right
	if (strict && only_columns.empty()) {
		for (auto &name : rs.names) {
			if (key_set.find(name) != key_set.end() || ignore_set.find(name) != ignore_set.end()) {
				continue;
			}
			if (lmap.find(name) == lmap.end()) {
				throw BinderException("table_diff: column \"%s\" exists on the right but not the left; column sets "
				                      "differ (use compare := 'intersect' to compare only common columns)",
				                      name);
			}
		}
	}

	// context columns are pulled from both sides, so they must exist in both
	for (auto &c : plan.context_cols) {
		if (lmap.find(c) == lmap.end() || rmap.find(c) == rmap.end()) {
			throw BinderException("table_diff: context column \"%s\" must exist in both relations", c);
		}
	}
	return plan;
}

//===--------------------------------------------------------------------===//
// SQL generation
//===--------------------------------------------------------------------===//

// Build a JSON object expression { 'col': <side>."col", ... } from a column
// list on the given alias (l / r).
string ContextObject(const string &alias, const vector<string> &cols) {
	if (cols.empty()) {
		return "CAST('{}' AS JSON)";
	}
	string args;
	for (idx_t i = 0; i < cols.size(); i++) {
		if (i) {
			args += ", ";
		}
		args += QuoteLiteral(cols[i]) + ", " + alias + "." + QuoteIdent(cols[i]);
	}
	return "json_object(" + args + ")";
}

// Generate the full diff query. status_col / diff_data_col give the output
// names for the meta columns; key_select controls whether the key columns are
// projected (table_diff) or not (summary).
string BuildDiffSQL(const DiffPlan &plan, const string &status_col, const string &diff_data_col, bool project_keys) {
	// join condition + key projection + key list (for dup detection)
	string join_cond, key_select, key_list;
	for (idx_t i = 0; i < plan.key_cols.size(); i++) {
		string q = QuoteIdent(plan.key_cols[i]);
		if (i) {
			join_cond += " AND ";
			key_list += ", ";
		}
		join_cond += "l." + q + " IS NOT DISTINCT FROM r." + q;
		key_list += q;
		if (project_keys) {
			key_select += "COALESCE(l." + q + ", r." + q + ") AS " + q + ", ";
		}
	}

	// equality of all compared value columns
	string all_eq = "TRUE";
	if (!plan.value_cols.empty()) {
		all_eq.clear();
		for (idx_t i = 0; i < plan.value_cols.size(); i++) {
			string q = QuoteIdent(plan.value_cols[i]);
			if (i) {
				all_eq += " AND ";
			}
			all_eq += "l." + q + " IS NOT DISTINCT FROM r." + q;
		}
	}

	// columns after diff_status: either the JSON diff_data (+ context objects) or,
	// in wide mode, one expanded set of columns per compared / context column
	string middle_select;
	if (plan.wide) {
		// per compared column: <c>_left, <c>_right, <c>_diff (the per-column result
		// of the same IS [NOT] DISTINCT FROM comparison used for the row status)
		for (auto &c : plan.value_cols) {
			string q = QuoteIdent(c);
			middle_select += ", l." + q + " AS " + QuoteIdent(c + "_left");
			middle_select += ", r." + q + " AS " + QuoteIdent(c + "_right");
			middle_select += ", (l." + q + " IS DISTINCT FROM r." + q + ") AS " + QuoteIdent(c + "_diff");
		}
		// per context column: <c>_left, <c>_right (no _diff; not compared)
		for (auto &c : plan.context_cols) {
			string q = QuoteIdent(c);
			middle_select += ", l." + q + " AS " + QuoteIdent(c + "_left");
			middle_select += ", r." + q + " AS " + QuoteIdent(c + "_right");
		}
	} else {
		// diff_data: JSON of only the differing columns, populated for 'differs' rows
		string diff_expr;
		if (plan.value_cols.empty()) {
			diff_expr = "CAST(NULL AS JSON)";
		} else {
			string merges;
			for (idx_t i = 0; i < plan.value_cols.size(); i++) {
				string q = QuoteIdent(plan.value_cols[i]);
				string lit = QuoteLiteral(plan.value_cols[i]);
				if (i) {
					merges += ", ";
				}
				merges += "CASE WHEN l." + q + " IS DISTINCT FROM r." + q + " THEN json_object(" + lit +
				          ", json_object('left', l." + q + ", 'right', r." + q + ")) ELSE CAST('{}' AS JSON) END";
			}
			// seed with an empty object so json_merge_patch always has >= 2 args
			diff_expr = "CASE WHEN l.__p AND r.__p AND NOT (" + all_eq +
			            ") THEN json_merge_patch(CAST('{}' AS JSON), " + merges + ") END";
		}
		middle_select = ", " + diff_expr + " AS " + QuoteIdent(diff_data_col);
		// context columns (only present when requested): JSON object or NULL on the
		// side that does not exist for this row
		if (plan.has_context) {
			middle_select +=
			    ", CASE WHEN l.__p THEN " + ContextObject("l", plan.context_cols) + " END AS \"left_context\"";
			middle_select +=
			    ", CASE WHEN r.__p THEN " + ContextObject("r", plan.context_cols) + " END AS \"right_context\"";
		}
	}

	string dup_cond = "EXISTS (SELECT 1 FROM __l GROUP BY " + key_list + " HAVING count(*) > 1) OR " +
	                  "EXISTS (SELECT 1 FROM __r GROUP BY " + key_list + " HAVING count(*) > 1)";

	string sql = "WITH __l AS (SELECT __t.*, TRUE AS __p FROM (SELECT * FROM " + plan.left + ") __t), " +
	             "__r AS (SELECT __t.*, TRUE AS __p FROM (SELECT * FROM " + plan.right + ") __t) " + "SELECT " +
	             key_select + "CASE WHEN r.__p IS NULL THEN 'left_only' WHEN l.__p IS NULL THEN 'right_only' WHEN " +
	             all_eq + " THEN 'matched' ELSE 'differs' END AS " + QuoteIdent(status_col) + middle_select +
	             " FROM __l AS l FULL OUTER JOIN __r AS r ON " + join_cond + " WHERE (CASE WHEN " + dup_cond +
	             " THEN error('table_diff: duplicate primary key values found in input') END) IS NULL";
	return sql;
}

unique_ptr<TableRef> ParseSubquery(ClientContext &context, const string &sql) {
	Parser parser(context.GetParserOptions());
	parser.ParseQuery(sql);
	if (parser.statements.size() != 1 || parser.statements[0]->type != StatementType::SELECT_STATEMENT) {
		throw InternalException("table_diff: generated query was not a single SELECT statement");
	}
	auto select = unique_ptr_cast<SQLStatement, SelectStatement>(std::move(parser.statements[0]));
	return make_uniq<SubqueryRef>(std::move(select));
}

//===--------------------------------------------------------------------===//
// bind_replace entry points
//===--------------------------------------------------------------------===//

unique_ptr<TableRef> TableDiffBindReplace(ClientContext &context, TableFunctionBindInput &input) {
	auto plan = ResolvePlan(context, input);

	string status_col = plan.prefix + "status";
	string diff_data_col = plan.prefix + "data";

	// collision check across output column names
	case_insensitive_set_t out_names;
	for (auto &k : plan.key_cols) {
		if (!out_names.insert(k).second) {
			throw BinderException("table_diff: duplicate key column \"%s\"", k);
		}
	}
	auto check = [&](const string &name) {
		if (out_names.find(name) != out_names.end()) {
			throw BinderException("table_diff: output column name \"%s\" collides with a key column; set a 'prefix' "
			                      "to disambiguate, e.g. prefix := 'cmp_'",
			                      name);
		}
		out_names.insert(name);
	};
	check(status_col);
	if (plan.wide) {
		for (auto &c : plan.value_cols) {
			check(c + "_left");
			check(c + "_right");
			check(c + "_diff");
		}
		for (auto &c : plan.context_cols) {
			check(c + "_left");
			check(c + "_right");
		}
	} else {
		check(diff_data_col);
		if (plan.has_context) {
			check("left_context");
			check("right_context");
		}
	}

	return ParseSubquery(context, BuildDiffSQL(plan, status_col, diff_data_col, /*project_keys=*/true));
}

unique_ptr<TableRef> TableDiffSummaryBindReplace(ClientContext &context, TableFunctionBindInput &input) {
	auto plan = ResolvePlan(context, input);
	// context/keys/wide are irrelevant to the summary; clear them so we only project status
	plan.has_context = false;
	plan.wide = false;
	string inner = BuildDiffSQL(plan, "status", "diff_data", /*project_keys=*/false);
	string sql = "SELECT count(*) FILTER (WHERE status = 'matched') AS n_matched, "
	             "count(*) FILTER (WHERE status = 'differs') AS n_differs, "
	             "count(*) FILTER (WHERE status = 'left_only') AS n_left_only, "
	             "count(*) FILTER (WHERE status = 'right_only') AS n_right_only FROM (" +
	             inner + ") __d";
	return ParseSubquery(context, sql);
}

//===--------------------------------------------------------------------===//
// Registration
//===--------------------------------------------------------------------===//

void AddDiffParameters(TableFunction &fun) {
	fun.named_parameters["pk"] = LogicalType::ANY; // string or list
	fun.named_parameters["additional_pk"] = LogicalType::LIST(LogicalType::VARCHAR);
	fun.named_parameters["compare"] = LogicalType::VARCHAR;
	fun.named_parameters["columns"] = LogicalType::LIST(LogicalType::VARCHAR);
	fun.named_parameters["ignore"] = LogicalType::LIST(LogicalType::VARCHAR);
	fun.named_parameters["prefix"] = LogicalType::VARCHAR;
	fun.named_parameters["context"] = LogicalType::LIST(LogicalType::VARCHAR);
	fun.named_parameters["wide"] = LogicalType::BOOLEAN;
}

void LoadInternal(ExtensionLoader &loader) {
	TableFunction table_diff("table_diff", {LogicalType::VARCHAR, LogicalType::VARCHAR}, nullptr, nullptr);
	table_diff.bind_replace = TableDiffBindReplace;
	AddDiffParameters(table_diff);
	loader.RegisterFunction(table_diff);

	TableFunction table_diff_summary("table_diff_summary", {LogicalType::VARCHAR, LogicalType::VARCHAR}, nullptr,
	                                 nullptr);
	table_diff_summary.bind_replace = TableDiffSummaryBindReplace;
	AddDiffParameters(table_diff_summary);
	loader.RegisterFunction(table_diff_summary);

	// tables_equal: scalar convenience wrapper over table_diff
	DefaultMacro tables_equal_macro = {
	    "main",
	    "tables_equal",
	    {"lhs", "rhs", nullptr},
	    {{"pk", "NULL"},
	     {"additional_pk", "[]"},
	     {"compare", "'strict'"},
	     {"columns", "NULL"},
	     {"ignore", "NULL"},
	     {nullptr, nullptr}},
	    "(SELECT count(*) = 0 FROM table_diff(lhs, rhs, pk := pk, additional_pk := additional_pk, compare := compare, "
	    "columns := columns, ignore := ignore) WHERE diff_status <> 'matched')"};
	auto macro_info = DefaultFunctionGenerator::CreateInternalMacroInfo(tables_equal_macro);
	loader.RegisterFunction(*macro_info);
}

} // namespace

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
