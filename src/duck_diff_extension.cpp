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

// Resolve the column names and types of a relation argument by binding it. The
// argument is a query the caller writes in SQL (a `FROM …` clause or a full
// `SELECT … FROM …`), mirroring the built-in query() function. No data is read
// and no temporary objects are created.
RelationSchema InspectRelation(ClientContext &context, optional_ptr<Binder> parent, const string &relation,
                               const char *side) {
	// The argument is a query, written as the caller would in SQL: a `FROM …`
	// clause or a full `SELECT … FROM …`. (A bare relation name is not a
	// statement and is rejected — write `FROM tbl`.)
	Parser parser(context.GetParserOptions());
	try {
		parser.ParseQuery(relation);
	} catch (const std::exception &e) {
		throw BinderException("table_diff: could not parse the %s argument (%s): %s; write it as a query, "
		                      "e.g. 'FROM tbl' or 'SELECT * FROM tbl'",
		                      side, relation, e.what());
	}
	if (parser.statements.size() != 1 || parser.statements[0]->type != StatementType::SELECT_STATEMENT) {
		throw BinderException("table_diff: the %s argument must be a single query, "
		                      "e.g. 'FROM tbl' or 'SELECT * FROM tbl'",
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

// A context column pulled from both sides. A column may exist on only one side
// (e.g. under require_matching_columns := false); the missing side renders as NULL.
struct ContextCol {
	string name;
	bool in_left;
	bool in_right;
	string type; // SQL type (from whichever side has it), used to cast the absent side's NULL
};

// A compared non-key column, with the type its comparison is performed at (the
// common super-type when the two sides differ and upcast_types is on, else the
// shared type). The type drives which value normalizations apply.
struct ValueCol {
	string name;
	LogicalType type;
};

struct DiffPlan {
	string left;
	string right;
	vector<string> key_cols;         // canonical (left) names, in order
	vector<ValueCol> value_cols;     // compared non-key columns, in order
	vector<ContextCol> context_cols; // extra non-compared columns expanded as <c>_left/<c>_right
	string prefix = "diff_";
	// value-normalization flags (applied to compared columns, not keys)
	bool has_tolerance = false;     // numeric_tolerance: |l-r| <= tolerance counts as equal
	string tolerance_sql;           // the tolerance as a SQL literal
	string timestamp_precision;     // date_trunc part applied to timestamp columns ("" = off)
	bool null_equals_empty = false; // treat NULL and '' as equal for VARCHAR columns
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

	// pk (required): a single column name or a list for a composite key
	auto pk_it = input.named_parameters.find("pk");
	if (pk_it == input.named_parameters.end() || pk_it->second.IsNull()) {
		throw BinderException("table_diff: the 'pk' parameter is required, e.g. pk := 'id' or pk := ['a','b']");
	}
	for (auto &c : ValueToStringList(pk_it->second)) {
		plan.key_cols.push_back(c);
	}
	if (plan.key_cols.empty()) {
		throw BinderException("table_diff: the 'pk' parameter must name at least one column");
	}

	// Schema-reconciliation flags (independent booleans, not a mode enum):
	//   require_matching_columns (default true): the two relations must have an
	//       identical column set — same names AND types. Any difference errors.
	//   upcast_types (default false): a column/key whose type differs across the
	//       two sides is reconciled to the common super-type instead of being
	//       treated as a mismatch.
	// require_matching_columns already demands identical types, so combining it
	// with upcast_types is contradictory and rejected.
	bool require_matching = true;
	if (auto *rm = FindParam(input, "require_matching_columns")) {
		require_matching = BooleanValue::Get(*rm);
	}
	bool upcast_types = false;
	if (auto *up = FindParam(input, "upcast_types")) {
		upcast_types = BooleanValue::Get(*up);
	}
	if (require_matching && upcast_types) {
		throw BinderException("table_diff: upcast_types := true cannot be combined with "
		                      "require_matching_columns := true (matching columns already requires identical "
		                      "types); set require_matching_columns := false to upcast differing types");
	}

	// columns / ignore / context lists
	vector<string> only_columns, ignore_columns;
	if (auto *cols = FindParam(input, "columns")) {
		only_columns = ValueToStringList(*cols);
	}
	if (auto *ign = FindParam(input, "ignore")) {
		ignore_columns = ValueToStringList(*ign);
	}
	vector<string> context_names;
	bool context_all = false;
	if (auto *ctx = FindParam(input, "context")) {
		context_names = ValueToStringList(*ctx);
		// context := ['*'] -> pull in every non-key column
		if (context_names.size() == 1 && context_names[0] == "*") {
			context_all = true;
			context_names.clear();
		}
	}
	if (auto *pre = FindParam(input, "prefix")) {
		plan.prefix = pre->ToString();
	}

	// value-normalization flags (applied to compared columns only, not keys)
	if (auto *tol = FindParam(input, "numeric_tolerance")) {
		double t = tol->GetValue<double>();
		if (t < 0) {
			throw BinderException("table_diff: numeric_tolerance must be >= 0, got %s", tol->ToString());
		}
		plan.has_tolerance = true;
		plan.tolerance_sql = "CAST(" + tol->ToString() + " AS DOUBLE)";
	}
	if (auto *tp = FindParam(input, "timestamp_precision")) {
		plan.timestamp_precision = tp->ToString();
	}
	if (auto *ne = FindParam(input, "null_equals_empty")) {
		plan.null_equals_empty = BooleanValue::Get(*ne);
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
		// Keys are never dropped, so their types must match. Without upcast_types
		// the types must be identical; with upcast_types they are reconciled to
		// the common super-type (the generated join and the COALESCE key
		// projection widen to it implicitly), erroring only when there is none.
		if (l_it->second != r_it->second) {
			if (!upcast_types) {
				throw BinderException("table_diff: key column \"%s\" has type %s on the left but %s on the right "
				                      "(set upcast_types := true to compare keys via their common type)",
				                      k, l_it->second.ToString(), r_it->second.ToString());
			}
			LogicalType common;
			if (!LogicalType::TryGetMaxLogicalType(context, l_it->second, r_it->second, common)) {
				throw BinderException("table_diff: key column \"%s\" has type %s on the left but %s on the right, "
				                      "and they have no common type",
				                      k, l_it->second.ToString(), r_it->second.ToString());
			}
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
		// Present on only one side: an unmatched column. Drop it unless the two
		// relations are required to match, in which case it is an error.
		if (l_it == lmap.end()) {
			if (require_matching) {
				throw BinderException("table_diff: column \"%s\" does not exist in the left relation "
				                      "(set require_matching_columns := false to compare only common columns)",
				                      c);
			}
			continue;
		}
		if (r_it == rmap.end()) {
			if (require_matching) {
				throw BinderException("table_diff: column \"%s\" exists on the left but not the right "
				                      "(set require_matching_columns := false to compare only common columns)",
				                      c);
			}
			continue;
		}
		// The type the comparison runs at: the shared type when they match, or
		// the common super-type when they differ and upcast_types reconciles them.
		LogicalType cmp_type = l_it->second;
		// Differing types: reconcile via the common super-type when upcast_types
		// is set (the generated IS [NOT] DISTINCT FROM widens implicitly), and
		// drop the column when there is none. Without upcast_types a type
		// mismatch is an unmatched column: dropped, or an error under
		// require_matching_columns.
		if (l_it->second != r_it->second) {
			if (upcast_types) {
				if (!LogicalType::TryGetMaxLogicalType(context, l_it->second, r_it->second, cmp_type)) {
					continue; // no common type: drop
				}
			} else {
				if (require_matching) {
					throw BinderException("table_diff: column \"%s\" has type %s on the left but %s on the right "
					                      "(set upcast_types := true to compare via their common type, or "
					                      "require_matching_columns := false to skip the column)",
					                      c, l_it->second.ToString(), r_it->second.ToString());
				}
				continue; // drop the type-mismatched column
			}
		}
		plan.value_cols.push_back(ValueCol {l_it->first, cmp_type});
	}
	// require_matching_columns: also reject columns present only on the right
	if (require_matching && only_columns.empty()) {
		for (auto &name : rs.names) {
			if (key_set.find(name) != key_set.end() || ignore_set.find(name) != ignore_set.end()) {
				continue;
			}
			if (lmap.find(name) == lmap.end()) {
				throw BinderException("table_diff: column \"%s\" exists on the right but not the left "
				                      "(set require_matching_columns := false to compare only common columns)",
				                      name);
			}
		}
	}

	// context := ['*']: every non-key column from EITHER side (a column present
	// on only one side shows NULL on the other). Compared columns are included
	// too — context is "the rest of the row", independent of what is compared;
	// this is what makes left_only / right_only rows show their full row. (In
	// wide mode a column that is also compared is emitted once, by the compared
	// loop, to avoid duplicate <c>_left / <c>_right output columns.)
	if (context_all) {
		case_insensitive_set_t seen;
		for (auto &name : ls.names) {
			if (key_set.find(name) == key_set.end()) {
				context_names.push_back(name);
				seen.insert(name);
			}
		}
		for (auto &name : rs.names) {
			if (key_set.find(name) == key_set.end() && seen.find(name) == seen.end()) {
				context_names.push_back(name);
			}
		}
	}

	// resolve each context column's presence + type; it must exist on at least
	// one side (the absent side renders as NULL)
	for (auto &name : context_names) {
		auto l_it = lmap.find(name);
		auto r_it = rmap.find(name);
		bool in_left = l_it != lmap.end();
		bool in_right = r_it != rmap.end();
		if (!in_left && !in_right) {
			throw BinderException("table_diff: context column \"%s\" does not exist in either relation", name);
		}
		ContextCol col;
		col.name = in_left ? l_it->first : r_it->first;
		col.in_left = in_left;
		col.in_right = in_right;
		col.type = (in_left ? l_it->second : r_it->second).ToString();
		plan.context_cols.push_back(std::move(col));
	}
	return plan;
}

//===--------------------------------------------------------------------===//
// SQL generation
//===--------------------------------------------------------------------===//

bool IsTimestampType(const LogicalType &t) {
	switch (t.id()) {
	case LogicalTypeId::TIMESTAMP:
	case LogicalTypeId::TIMESTAMP_TZ:
	case LogicalTypeId::TIMESTAMP_SEC:
	case LogicalTypeId::TIMESTAMP_MS:
	case LogicalTypeId::TIMESTAMP_NS:
		return true;
	default:
		return false;
	}
}

// One side's operand for a compared column, after the normalizations that
// rewrite the value itself: timestamp truncation and NULL/'' unification.
// (numeric_tolerance is not an operand rewrite — see ColumnEqual.)
string NormOperand(const DiffPlan &plan, const string &alias, const ValueCol &col) {
	string e = alias + "." + QuoteIdent(col.name);
	if (!plan.timestamp_precision.empty() && IsTimestampType(col.type)) {
		e = "date_trunc(" + QuoteLiteral(plan.timestamp_precision) + ", " + e + ")";
	}
	if (plan.null_equals_empty && col.type.id() == LogicalTypeId::VARCHAR) {
		e = "NULLIF(" + e + ", '')";
	}
	return e;
}

// Boolean SQL expression that is TRUE when the two sides of a compared column
// are considered equal, honoring the value-normalization flags. NULL-safe
// (always TRUE/FALSE, never NULL), like IS NOT DISTINCT FROM.
string ColumnEqual(const DiffPlan &plan, const ValueCol &col) {
	string l = NormOperand(plan, "l", col);
	string r = NormOperand(plan, "r", col);
	string indf = "(" + l + " IS NOT DISTINCT FROM " + r + ")";
	if (plan.has_tolerance && col.type.IsNumeric()) {
		// equal if bit-identical (covers both-NULL) or within the tolerance band
		return "(" + indf + " OR (" + l + " IS NOT NULL AND " + r + " IS NOT NULL AND abs(" + l + " - " + r +
		       ") <= " + plan.tolerance_sql + "))";
	}
	return indf;
}

// Negation of ColumnEqual: TRUE when the two sides differ.
string ColumnDistinct(const DiffPlan &plan, const ValueCol &col) {
	return "(NOT " + ColumnEqual(plan, col) + ")";
}

// SQL expression for a context column's value on one side: the column if it
// exists on that side, otherwise a typed NULL.
string ContextValue(const string &alias, const ContextCol &col, bool is_left) {
	bool present = is_left ? col.in_left : col.in_right;
	if (present) {
		return alias + "." + QuoteIdent(col.name);
	}
	return "CAST(NULL AS " + col.type + ")";
}

// Generate the full diff query. status_col / diff_data_col give the output names
// for the meta columns; project_keys controls whether the key columns are
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
			if (i) {
				all_eq += " AND ";
			}
			all_eq += ColumnEqual(plan, plan.value_cols[i]);
		}
	}

	// diff_data: JSON of only the differing compared columns, populated for
	// 'different' rows. (diff_columns is not emitted -- it is json_keys(diff_data).)
	string diff_expr;
	if (plan.value_cols.empty()) {
		diff_expr = "CAST(NULL AS JSON)";
	} else {
		string merges;
		for (idx_t i = 0; i < plan.value_cols.size(); i++) {
			string q = QuoteIdent(plan.value_cols[i].name);
			string lit = QuoteLiteral(plan.value_cols[i].name);
			if (i) {
				merges += ", ";
			}
			// the diff is decided by the normalized comparison, but the JSON shows the raw values
			merges += "CASE WHEN " + ColumnDistinct(plan, plan.value_cols[i]) + " THEN json_object(" + lit +
			          ", json_object('left', l." + q + ", 'right', r." + q + ")) ELSE CAST('{}' AS JSON) END";
		}
		// seed with an empty object so json_merge_patch always has >= 2 args
		diff_expr = "CASE WHEN l.__p AND r.__p AND NOT (" + all_eq + ") THEN json_merge_patch(CAST('{}' AS JSON), " +
		            merges + ") END";
	}

	// one table: the diff_data JSON, then per compared column <c>_left / <c>_right
	// (native typed values) / <c>_diff_status, then per context column (not
	// compared) <c>_left / <c>_right. The status mirrors the row status:
	// left_only / right_only for one-sided rows, else identical / different.
	string middle_select = ", " + diff_expr + " AS " + QuoteIdent(diff_data_col);
	for (auto &c : plan.value_cols) {
		string q = QuoteIdent(c.name);
		string status = "CASE WHEN r.__p IS NULL THEN 'left_only' WHEN l.__p IS NULL THEN 'right_only' WHEN " +
		                ColumnEqual(plan, c) + " THEN 'identical' ELSE 'different' END";
		middle_select += ", l." + q + " AS " + QuoteIdent(c.name + "_left");
		middle_select += ", r." + q + " AS " + QuoteIdent(c.name + "_right");
		middle_select += ", " + status + " AS " + QuoteIdent(c.name + "_diff_status");
	}
	{
		// context columns expand to <c>_left / <c>_right; one also compared is
		// already emitted above; one present on only one side is NULL there.
		case_insensitive_set_t compared;
		for (auto &c : plan.value_cols) {
			compared.insert(c.name);
		}
		for (auto &c : plan.context_cols) {
			if (compared.find(c.name) != compared.end()) {
				continue;
			}
			middle_select += ", " + ContextValue("l", c, true) + " AS " + QuoteIdent(c.name + "_left");
			middle_select += ", " + ContextValue("r", c, false) + " AS " + QuoteIdent(c.name + "_right");
		}
	}

	string dup_cond = "EXISTS (SELECT 1 FROM __l GROUP BY " + key_list + " HAVING count(*) > 1) OR " +
	                  "EXISTS (SELECT 1 FROM __r GROUP BY " + key_list + " HAVING count(*) > 1)";

	string sql = "WITH __l AS (SELECT __t.*, TRUE AS __p FROM (" + plan.left + ") __t), " +
	             "__r AS (SELECT __t.*, TRUE AS __p FROM (" + plan.right + ") __t) " + "SELECT " + key_select +
	             "CASE WHEN r.__p IS NULL THEN 'left_only' WHEN l.__p IS NULL THEN 'right_only' WHEN " + all_eq +
	             " THEN 'identical' ELSE 'different' END AS " + QuoteIdent(status_col) + middle_select +
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
	check(diff_data_col);
	case_insensitive_set_t compared;
	for (auto &c : plan.value_cols) {
		check(c.name + "_left");
		check(c.name + "_right");
		check(c.name + "_diff_status");
		compared.insert(c.name);
	}
	for (auto &c : plan.context_cols) {
		// a context column that is also compared is emitted only once (above)
		if (compared.find(c.name) != compared.end()) {
			continue;
		}
		check(c.name + "_left");
		check(c.name + "_right");
	}

	return ParseSubquery(context, BuildDiffSQL(plan, status_col, diff_data_col, /*project_keys=*/true));
}

unique_ptr<TableRef> TableDiffSummaryBindReplace(ClientContext &context, TableFunctionBindInput &input) {
	auto plan = ResolvePlan(context, input);
	// context/keys are irrelevant to the summary; clear context so we only project status
	plan.context_cols.clear();
	string inner = BuildDiffSQL(plan, "status", "diff_data", /*project_keys=*/false);
	// counts per status, the total, and each as a percentage of the total
	// (NULL percentages when there are no rows, to avoid division by zero)
	string sql = "SELECT n_identical, n_different, n_left_only, n_right_only, n_total, "
	             "round(100.0 * n_identical / nullif(n_total, 0), 2) AS pct_identical, "
	             "round(100.0 * n_different / nullif(n_total, 0), 2) AS pct_different, "
	             "round(100.0 * n_left_only / nullif(n_total, 0), 2) AS pct_left_only, "
	             "round(100.0 * n_right_only / nullif(n_total, 0), 2) AS pct_right_only FROM ("
	             "SELECT count(*) FILTER (WHERE status = 'identical') AS n_identical, "
	             "count(*) FILTER (WHERE status = 'different') AS n_different, "
	             "count(*) FILTER (WHERE status = 'left_only') AS n_left_only, "
	             "count(*) FILTER (WHERE status = 'right_only') AS n_right_only, "
	             "count(*) AS n_total FROM (" +
	             inner + ") __d) __c";
	return ParseSubquery(context, sql);
}

// schema_diff(left, right): one row per column (union of both schemas) with the
// type on each side and a status (identical / type_differs / left_only /
// right_only). Computed entirely from the bound schemas; reads no data.
unique_ptr<TableRef> SchemaDiffBindReplace(ClientContext &context, TableFunctionBindInput &input) {
	if (input.inputs.size() < 2) {
		throw BinderException("schema_diff: requires two relation arguments (left, right)");
	}
	auto left = input.inputs[0].ToString();
	auto right = input.inputs[1].ToString();
	auto ls = InspectRelation(context, input.binder, left, "left");
	auto rs = InspectRelation(context, input.binder, right, "right");

	case_insensitive_map_t<LogicalType> rmap;
	for (idx_t i = 0; i < rs.names.size(); i++) {
		rmap[rs.names[i]] = rs.types[i];
	}

	string rows;
	auto add_row = [&](const string &name, const string &left_type, bool has_left, const string &right_type,
	                   bool has_right, const string &status) {
		if (!rows.empty()) {
			rows += ", ";
		}
		rows += "(" + QuoteLiteral(name) + ", " + (has_left ? QuoteLiteral(left_type) : string("NULL")) + ", " +
		        (has_right ? QuoteLiteral(right_type) : string("NULL")) + ", " + QuoteLiteral(status) + ")";
	};

	case_insensitive_set_t seen;
	for (idx_t i = 0; i < ls.names.size(); i++) {
		seen.insert(ls.names[i]);
		string lt = ls.types[i].ToString();
		auto r_it = rmap.find(ls.names[i]);
		if (r_it == rmap.end()) {
			add_row(ls.names[i], lt, true, "", false, "left_only");
		} else {
			string rt = r_it->second.ToString();
			add_row(ls.names[i], lt, true, rt, true, lt == rt ? "identical" : "type_differs");
		}
	}
	for (idx_t i = 0; i < rs.names.size(); i++) {
		if (seen.find(rs.names[i]) != seen.end()) {
			continue;
		}
		add_row(rs.names[i], "", false, rs.types[i].ToString(), true, "right_only");
	}

	string sql;
	if (rows.empty()) {
		sql = "SELECT NULL::VARCHAR AS column_name, NULL::VARCHAR AS left_type, NULL::VARCHAR AS right_type, "
		      "NULL::VARCHAR AS status WHERE false";
	} else {
		sql = "SELECT * FROM (VALUES " + rows + ") AS t(column_name, left_type, right_type, status)";
	}
	return ParseSubquery(context, sql);
}

//===--------------------------------------------------------------------===//
// Registration
//===--------------------------------------------------------------------===//

void AddDiffParameters(TableFunction &fun) {
	fun.named_parameters["pk"] = LogicalType::ANY; // string or list
	fun.named_parameters["require_matching_columns"] = LogicalType::BOOLEAN;
	fun.named_parameters["upcast_types"] = LogicalType::BOOLEAN;
	fun.named_parameters["columns"] = LogicalType::LIST(LogicalType::VARCHAR);
	fun.named_parameters["ignore"] = LogicalType::LIST(LogicalType::VARCHAR);
	fun.named_parameters["numeric_tolerance"] = LogicalType::DOUBLE;
	fun.named_parameters["timestamp_precision"] = LogicalType::VARCHAR;
	fun.named_parameters["null_equals_empty"] = LogicalType::BOOLEAN;
	fun.named_parameters["prefix"] = LogicalType::VARCHAR;
	fun.named_parameters["context"] = LogicalType::LIST(LogicalType::VARCHAR);
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

	TableFunction schema_diff("schema_diff", {LogicalType::VARCHAR, LogicalType::VARCHAR}, nullptr, nullptr);
	schema_diff.bind_replace = SchemaDiffBindReplace;
	loader.RegisterFunction(schema_diff);

	// tables_equal: scalar convenience wrapper over table_diff
	DefaultMacro tables_equal_macro = {
	    "main",
	    "tables_equal",
	    {"lhs", "rhs", nullptr},
	    {{"pk", "NULL"},
	     {"require_matching_columns", "true"},
	     {"upcast_types", "false"},
	     {"columns", "NULL"},
	     {"ignore", "NULL"},
	     {nullptr, nullptr}},
	    "(SELECT count(*) = 0 FROM table_diff(lhs, rhs, pk := pk, "
	    "require_matching_columns := require_matching_columns, upcast_types := upcast_types, "
	    "columns := columns, ignore := ignore) WHERE diff_status <> 'identical')"};
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
