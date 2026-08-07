#!/usr/bin/env bash
# Tests for scripts/probe_local_schema_drift.sh.
# These tests use mock psql only; they do NOT touch a real database.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

DETECTOR_SCRIPT="$REPO_ROOT/scripts/probe_local_schema_drift.sh"
TARGET_DB_URL="postgres://target_user:target_secret@localhost:5432/target_db"
REMOTE_TARGET_DB_URL="postgres://target_user:target_secret@db.example.com:5432/target_db"

write_schema_fixture_psql_mock() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf 'psql %s\n' "$*" >> "$MOCK_CALL_LOG"

sql=""
file_arg=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-c" ] || [ "$prev" = "-tAc" ]; then
        sql="$arg"
    fi
    if [ "$prev" = "-f" ]; then
        file_arg="$arg"
    fi
    prev="$arg"
done

if [ -n "$file_arg" ]; then
    printf 'apply|%s|%s\n' "$*" "$file_arg" >> "$MOCK_ROUTE_LOG"
    if [ "${MOCK_ORACLE_BUILD_FAIL:-0}" = "1" ]; then
        echo "fixture migration failed" >&2
        exit 42
    fi
    exit 0
fi

if [[ "$sql" == *"CREATE DATABASE"* ]]; then
    db_name="$(printf '%s\n' "$sql" | sed -E 's/.*CREATE DATABASE "?([A-Za-z0-9_]+)"?.*/\1/')"
    printf 'create|%s\n' "$db_name" >> "$MOCK_ROUTE_LOG"
    printf '%s\n' "$db_name" > "$MOCK_SCRATCH_DB_FILE"
    exit 0
fi

if [[ "$sql" == *"DROP DATABASE"* ]]; then
    db_name="$(printf '%s\n' "$sql" | sed -E 's/.*DROP DATABASE IF EXISTS "?([A-Za-z0-9_]+)"?.*/\1/')"
    printf 'drop|%s\n' "$db_name" >> "$MOCK_ROUTE_LOG"
    exit 0
fi

if [[ "$sql" == *"information_schema.columns"* ]]; then
    scratch_db="$(cat "$MOCK_SCRATCH_DB_FILE" 2>/dev/null || true)"
    if [[ "$*" == *"$MOCK_TARGET_DB_URL"* ]]; then
        printf 'target_schema_query\n' >> "$MOCK_ROUTE_LOG"
        case "${MOCK_SCHEMA_CASE:-identical}" in
            identical)
                cat "$MOCK_FIXTURE_DIR/target_identical.columns"
                ;;
            target_only_table)
                cat "$MOCK_FIXTURE_DIR/target_only_table.columns"
                ;;
            missing)
                cat "$MOCK_FIXTURE_DIR/target_missing.columns"
                ;;
            unexpected)
                cat "$MOCK_FIXTURE_DIR/target_unexpected.columns"
                ;;
            multiple)
                cat "$MOCK_FIXTURE_DIR/target_multiple.columns"
                ;;
            *)
                echo "unknown schema case: $MOCK_SCHEMA_CASE" >&2
                exit 2
                ;;
        esac
        exit 0
    fi

    if [ -n "$scratch_db" ] && [[ "$*" == *"$scratch_db"* ]]; then
        printf 'oracle_schema_query|%s\n' "$scratch_db" >> "$MOCK_ROUTE_LOG"
        cat "$MOCK_FIXTURE_DIR/oracle.columns"
        exit 0
    fi

    echo "schema query did not identify target or scratch database" >&2
    exit 2
fi

if [[ "$sql" == *"FROM rate_cards"* && "$sql" == *"shared_minimum_spend_cents"* ]]; then
    scratch_db="$(cat "$MOCK_SCRATCH_DB_FILE" 2>/dev/null || true)"
    if [[ "$*" == *"$MOCK_TARGET_DB_URL"* ]]; then
        printf 'target_rate_cards_value_query\n' >> "$MOCK_ROUTE_LOG"
        case "${MOCK_VALUE_CASE:-agreement}" in
            agreement)
                cat "$MOCK_FIXTURE_DIR/target_rate_cards_agreement.values"
                ;;
            legacy_shared_minimum)
                cat "$MOCK_FIXTURE_DIR/target_rate_cards_legacy_shared_minimum.values"
                ;;
            duplicate_active)
                cat "$MOCK_FIXTURE_DIR/target_rate_cards_duplicate_active.values"
                ;;
            missing_launch_row)
                cat "$MOCK_FIXTURE_DIR/target_rate_cards_missing_launch.values"
                ;;
            query_fail)
                echo "fixture target value query failed" >&2
                exit 44
                ;;
            *)
                echo "unknown value case: $MOCK_VALUE_CASE" >&2
                exit 2
                ;;
        esac
        exit 0
    fi

    if [ -n "$scratch_db" ] && [[ "$*" == *"$scratch_db"* ]]; then
        printf 'oracle_rate_cards_value_query|%s\n' "$scratch_db" >> "$MOCK_ROUTE_LOG"
        if [ "${MOCK_ORACLE_VALUE_QUERY_FAIL:-0}" = "1" ]; then
            echo "fixture oracle value query failed" >&2
            exit 43
        fi
        case "${MOCK_ORACLE_VALUE_CASE:-agreement}" in
            agreement)
                cat "$MOCK_FIXTURE_DIR/oracle_rate_cards.values"
                ;;
            duplicate_active)
                cat "$MOCK_FIXTURE_DIR/oracle_rate_cards_duplicate_active.values"
                ;;
            empty)
                cat "$MOCK_FIXTURE_DIR/oracle_rate_cards_empty.values"
                ;;
            *)
                echo "unknown oracle value case: $MOCK_ORACLE_VALUE_CASE" >&2
                exit 2
                ;;
        esac
        exit 0
    fi

    echo "rate_cards value query did not identify target or scratch database" >&2
    exit 2
fi

exit 0
MOCK
    chmod +x "$path"
}

write_schema_fixtures() {
    local fixture_dir="$1"
    mkdir -p "$fixture_dir"

    cat > "$fixture_dir/oracle.columns" <<'EOF'
public|accounts|id|uuid|NO|
public|accounts|email|text|NO|
public|invoices|id|uuid|NO|
public|invoices|total_cents|bigint|NO|0
public|usage_records|id|uuid|NO|
public|usage_records|quantity|bigint|NO|0
EOF

    cp "$fixture_dir/oracle.columns" "$fixture_dir/target_identical.columns"

    cat > "$fixture_dir/target_missing.columns" <<'EOF'
public|accounts|id|uuid|NO|
public|invoices|id|uuid|NO|
public|invoices|total_cents|bigint|NO|0
public|usage_records|id|uuid|NO|
public|usage_records|quantity|bigint|NO|0
EOF

    cat > "$fixture_dir/target_unexpected.columns" <<'EOF'
public|accounts|id|uuid|NO|
public|accounts|email|text|NO|
public|accounts|legacy_code|text|YES|
public|invoices|id|uuid|NO|
public|invoices|total_cents|bigint|NO|0
public|usage_records|id|uuid|NO|
public|usage_records|quantity|bigint|NO|0
EOF

    cat > "$fixture_dir/target_multiple.columns" <<'EOF'
public|accounts|id|uuid|NO|
public|accounts|legacy_code|text|YES|
public|invoices|id|uuid|NO|
public|usage_records|id|uuid|NO|
EOF

    cat > "$fixture_dir/target_only_table.columns" <<'EOF'
public|accounts|id|uuid|NO|
public|accounts|email|text|NO|
public|debug_events|id|uuid|NO|
public|debug_events|payload|jsonb|NO|
public|invoices|id|uuid|NO|
public|invoices|total_cents|bigint|NO|0
public|usage_records|id|uuid|NO|
public|usage_records|quantity|bigint|NO|0
EOF

    cat > "$fixture_dir/oracle_rate_cards.values" <<'EOF'
rate_cards|launch-2026|shared_minimum_spend_cents|1500
EOF

    cat > "$fixture_dir/oracle_rate_cards_duplicate_active.values" <<'EOF'
rate_cards|launch-2026|shared_minimum_spend_cents|1500
rate_cards|launch-2026|shared_minimum_spend_cents|1500
EOF

    : > "$fixture_dir/oracle_rate_cards_empty.values"

    cp "$fixture_dir/oracle_rate_cards.values" "$fixture_dir/target_rate_cards_agreement.values"

    cat > "$fixture_dir/target_rate_cards_legacy_shared_minimum.values" <<'EOF'
rate_cards|launch-2026|shared_minimum_spend_cents|500
EOF

    cat > "$fixture_dir/target_rate_cards_duplicate_active.values" <<'EOF'
rate_cards|launch-2026|shared_minimum_spend_cents|500
rate_cards|launch-2026|shared_minimum_spend_cents|1500
EOF

    : > "$fixture_dir/target_rate_cards_missing_launch.values"
}

run_detector_with_case() {
    local tmp_dir="$1" schema_case="$2" oracle_build_fail="${3:-0}" value_case="${4:-agreement}" oracle_value_query_fail="${5:-0}" oracle_value_case="${6:-agreement}"

    mkdir -p "$tmp_dir/bin" "$tmp_dir/fixtures"
    write_schema_fixtures "$tmp_dir/fixtures"
    write_schema_fixture_psql_mock "$tmp_dir/bin/psql"

    export MOCK_CALL_LOG="$tmp_dir/psql_calls.log"
    export MOCK_ROUTE_LOG="$tmp_dir/routes.log"
    export MOCK_SCRATCH_DB_FILE="$tmp_dir/scratch_db_name"
    export MOCK_FIXTURE_DIR="$tmp_dir/fixtures"
    export MOCK_TARGET_DB_URL="$TARGET_DB_URL"
    export MOCK_SCHEMA_CASE="$schema_case"
    export MOCK_ORACLE_BUILD_FAIL="$oracle_build_fail"
    export MOCK_VALUE_CASE="$value_case"
    export MOCK_ORACLE_VALUE_QUERY_FAIL="$oracle_value_query_fail"
    export MOCK_ORACLE_VALUE_CASE="$oracle_value_case"
    : > "$MOCK_CALL_LOG"
    : > "$MOCK_ROUTE_LOG"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$TARGET_DB_URL" \
        bash "$DETECTOR_SCRIPT" 2>&1
    ) || exit_code=$?

    printf '%s\n' "$exit_code" > "$tmp_dir/exit_code"
    printf '%s\n' "$output" > "$tmp_dir/output"
}

assert_created_database_was_dropped() {
    local route_log="$1" message="$2"
    local created dropped

    created="$(awk -F'|' '$1 == "create" { print $2; exit }' "$route_log")"
    dropped="$(awk -F'|' '$1 == "drop" { print $2; exit }' "$route_log")"

    assert_ne "$created" "" "$message should create a scratch database"
    assert_ne "$dropped" "" "$message should drop a scratch database"
    assert_not_contains "$created" " " "$message should use a simple scratch database name"
    assert_eq "$dropped" "$created" "$message should drop the created scratch database"
}

assert_output_order() {
    local output="$1" first="$2" second="$3" message="$4"
    if python3 - "$output" "$first" "$second" <<'PY'
import sys

output, first, second = sys.argv[1:4]
first_index = output.find(first)
second_index = output.find(second)
if first_index < 0 or second_index < 0 or first_index >= second_index:
    raise SystemExit(1)
PY
    then
        pass "$message"
    else
        fail "$message (expected '$first' before '$second')"
    fi
}

test_identical_schema_exits_zero_and_reports_clean() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "identical"

    local output exit_code routes
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"
    routes="$(cat "$tmp_dir/routes.log")"

    assert_eq "$exit_code" "0" "identical schemas should exit 0"
    assert_contains "$output" "no local schema drift" "identical schemas should emit clean verdict"
    assert_not_contains "$output" "DRIFT" "identical schemas should not emit fatal drift"
    assert_contains "$routes" "oracle_schema_query" "identical case should inspect scratch oracle schema"
    assert_contains "$routes" "target_schema_query" "identical case should inspect target schema"
    assert_created_database_was_dropped "$tmp_dir/routes.log" "identical success cleanup"
}

test_rejects_non_local_database_hosts_before_running_psql() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    mkdir -p "$tmp_dir/bin"
    write_schema_fixture_psql_mock "$tmp_dir/bin/psql"

    export MOCK_CALL_LOG="$tmp_dir/psql_calls.log"
    export MOCK_ROUTE_LOG="$tmp_dir/routes.log"
    export MOCK_SCRATCH_DB_FILE="$tmp_dir/scratch_db_name"
    export MOCK_FIXTURE_DIR="$tmp_dir/fixtures"
    export MOCK_TARGET_DB_URL="$REMOTE_TARGET_DB_URL"
    : > "$MOCK_CALL_LOG"
    : > "$MOCK_ROUTE_LOG"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$REMOTE_TARGET_DB_URL" \
        bash "$DETECTOR_SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "non-local DATABASE_URL hosts should be rejected"
    assert_contains "$output" "must point to a local PostgreSQL host" \
        "non-local DATABASE_URL rejection should explain the local-host requirement"

    local calls routes
    calls="$(cat "$MOCK_CALL_LOG")"
    routes="$(cat "$MOCK_ROUTE_LOG")"
    assert_eq "$calls" "" "non-local DATABASE_URL hosts should fail before any psql invocation"
    assert_eq "$routes" "" "non-local DATABASE_URL hosts should not create scratch databases"
}

test_missing_target_column_fails_and_names_column() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "missing"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "1" "missing target column should exit 1"
    assert_contains "$output" "accounts.email" "missing target column should name exact table.column"
    assert_contains "$output" "missing" "missing target column should explain missing status"
    assert_not_contains "$output" "no local schema drift" "missing target column should not emit clean verdict"
}

test_unexpected_target_column_fails_and_names_column() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "unexpected"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "1" "unexpected target column should exit 1"
    assert_contains "$output" "accounts.legacy_code" "unexpected target column should name exact table.column"
    assert_contains "$output" "unexpected" "unexpected target column should include unexpected"
}

test_target_only_table_is_informational() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "target_only_table"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "0" "target-only table should exit 0"
    assert_contains "$output" "debug_events" "target-only table should be reported for operator context"
    assert_contains "$output" "informational" "target-only table should be informational"
    assert_contains "$output" "no local schema drift" "target-only table should still emit clean verdict"
}

test_reference_value_agreement_exits_zero_and_queries_both_databases() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "identical" "0" "agreement"

    local output exit_code routes
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"
    routes="$(cat "$tmp_dir/routes.log")"

    assert_eq "$exit_code" "0" "matching rate_cards reference values should exit 0"
    assert_contains "$output" "no local schema drift" "matching reference values should emit clean verdict"
    assert_contains "$routes" "oracle_rate_cards_value_query" "matching case should inspect scratch rate_cards values"
    assert_contains "$routes" "target_rate_cards_value_query" "matching case should inspect target rate_cards values"
}

test_legacy_shared_minimum_value_drift_fails_and_names_expected_and_found() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "identical" "0" "legacy_shared_minimum"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "1" "legacy shared minimum value drift should exit 1"
    assert_contains "$output" "rate_cards" "legacy value drift should name rate_cards"
    assert_contains "$output" "launch-2026" "legacy value drift should name the launch rate card row"
    assert_contains "$output" "shared_minimum_spend_cents" "legacy value drift should name the drifted column"
    assert_contains "$output" "expected 1500" "legacy value drift should name expected oracle value"
    assert_contains "$output" "found 500" "legacy value drift should name found target value"
    assert_not_contains "$output" "no local schema drift" "legacy value drift should not emit clean verdict"
}

test_duplicate_active_target_reference_rows_are_fatal() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "identical" "0" "duplicate_active"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "1" "duplicate active target reference rows should exit 1"
    assert_contains "$output" "duplicate target rows" "duplicate active target rows should have a distinct classification"
    assert_contains "$output" "rate_cards" "duplicate active target rows should name rate_cards"
    assert_contains "$output" "launch-2026" "duplicate active target rows should name launch-2026"
    assert_contains "$output" "shared_minimum_spend_cents" "duplicate active target rows should name the guarded column"
    assert_contains "$output" "expected exactly 1" "duplicate active target rows should state the required cardinality"
    assert_contains "$output" "found 2" "duplicate active target rows should report the observed cardinality"
    assert_not_contains "$output" "no local schema drift" "duplicate active target rows should not emit clean verdict"
}

test_duplicate_active_oracle_reference_rows_are_fatal() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "identical" "0" "agreement" "0" "duplicate_active"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "1" "duplicate active oracle reference rows should exit 1"
    assert_contains "$output" "duplicate oracle rows" "duplicate active oracle rows should have a distinct classification"
    assert_contains "$output" "rate_cards" "duplicate active oracle rows should name rate_cards"
    assert_contains "$output" "launch-2026" "duplicate active oracle rows should name launch-2026"
    assert_contains "$output" "shared_minimum_spend_cents" "duplicate active oracle rows should name the guarded column"
    assert_contains "$output" "expected exactly 1" "duplicate active oracle rows should state the required cardinality"
    assert_contains "$output" "found 2" "duplicate active oracle rows should report the observed cardinality"
    assert_not_contains "$output" "no local schema drift" "duplicate active oracle rows should not emit clean verdict"
}

test_missing_target_reference_row_fails_with_missing_row_classification() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "identical" "0" "missing_launch_row"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "1" "missing target launch rate_cards row should exit 1"
    assert_contains "$output" "missing row" "missing target reference row should classify the row as missing"
    assert_contains "$output" "rate_cards" "missing target reference row should name rate_cards"
    assert_contains "$output" "launch-2026" "missing target reference row should name launch-2026"
    assert_not_contains "$output" "no local schema drift" "missing target reference row should not emit clean verdict"
}

test_oracle_reference_value_query_failure_is_distinct_and_not_clean() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "identical" "0" "agreement" "1"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "1" "scratch reference-value query failure should exit 1"
    assert_contains "$output" "reference" "scratch value query failure should name reference-value inspection"
    assert_contains "$output" "scratch" "scratch value query failure should name scratch oracle"
    assert_not_contains "$output" "no local schema drift" "scratch value query failure should not emit clean verdict"
}

test_empty_oracle_reference_values_are_fatal_and_not_clean() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "identical" "0" "legacy_shared_minimum" "0" "empty"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "1" "empty scratch reference values should exit 1"
    assert_contains "$output" "missing oracle row" "empty scratch reference values should classify the oracle row as missing"
    assert_contains "$output" "rate_cards" "empty scratch reference values should name rate_cards"
    assert_contains "$output" "launch-2026" "empty scratch reference values should name launch-2026"
    assert_contains "$output" "shared_minimum_spend_cents" "empty scratch reference values should name the required column"
    assert_not_contains "$output" "no local schema drift" "empty scratch reference values should not emit clean verdict"
}

test_target_reference_query_failure_still_reports_column_drift() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "missing" "0" "query_fail"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "1" "target reference-value query failure should exit 1"
    assert_contains "$output" "accounts.email" "target reference query failure should still report column drift"
    assert_contains "$output" "missing accounts.email" "target reference query failure should keep missing-column classification"
    assert_contains "$output" "Failed to inspect target reference values" "target reference query failure should report value inspection failure"
    assert_not_contains "$output" "no local schema drift" "target reference query failure should not emit clean verdict"
}

test_multiple_column_differences_are_deterministic_and_complete() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "multiple"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "1" "multiple column differences should exit 1"
    assert_contains "$output" "accounts.email" "multiple differences should include accounts.email"
    assert_contains "$output" "accounts.legacy_code" "multiple differences should include accounts.legacy_code"
    assert_contains "$output" "invoices.total_cents" "multiple differences should include invoices.total_cents"
    assert_contains "$output" "usage_records.quantity" "multiple differences should include usage_records.quantity"
    assert_output_order "$output" "accounts.email" "accounts.legacy_code" \
        "multiple differences should sort accounts.email before accounts.legacy_code"
    assert_output_order "$output" "accounts.legacy_code" "invoices.total_cents" \
        "multiple differences should sort accounts before invoices"
    assert_output_order "$output" "invoices.total_cents" "usage_records.quantity" \
        "multiple differences should sort invoices before usage_records"
}

test_oracle_build_failure_is_distinct_and_not_clean() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    run_detector_with_case "$tmp_dir" "identical" "1"

    local output exit_code
    output="$(cat "$tmp_dir/output")"
    exit_code="$(cat "$tmp_dir/exit_code")"

    assert_eq "$exit_code" "1" "scratch migration failure should exit 1"
    assert_contains "$output" "scratch" "scratch migration failure should name scratch/oracle build"
    assert_contains "$output" "oracle" "scratch migration failure should name oracle build"
    assert_not_contains "$output" "no local schema drift" "scratch migration failure should not emit clean verdict"
    assert_created_database_was_dropped "$tmp_dir/routes.log" "oracle failure cleanup"
}

test_cleanup_uses_per_invocation_scratch_database_name() {
    local first_tmp second_tmp
    first_tmp="$(mktemp -d)"
    second_tmp="$(mktemp -d)"
    trap "rm -rf '$first_tmp' '$second_tmp'" RETURN

    run_detector_with_case "$first_tmp" "identical"
    run_detector_with_case "$second_tmp" "identical"

    local first_created first_dropped second_created second_dropped
    first_created="$(awk -F'|' '$1 == "create" { print $2; exit }' "$first_tmp/routes.log")"
    first_dropped="$(awk -F'|' '$1 == "drop" { print $2; exit }' "$first_tmp/routes.log")"
    second_created="$(awk -F'|' '$1 == "create" { print $2; exit }' "$second_tmp/routes.log")"
    second_dropped="$(awk -F'|' '$1 == "drop" { print $2; exit }' "$second_tmp/routes.log")"

    assert_ne "$first_created" "" "first run should create a scratch database"
    assert_ne "$second_created" "" "second run should create a scratch database"
    assert_eq "$first_dropped" "$first_created" "first run should drop its own scratch database"
    assert_eq "$second_dropped" "$second_created" "second run should drop its own scratch database"
    assert_ne "$first_created" "$second_created" "scratch database names should be unique per invocation"
}

test_cleanup_trap_is_installed_before_scratch_database_creation() {
    assert_file_exists "$DETECTOR_SCRIPT" "detector script should exist"

    local script_text
    script_text="$(cat "$DETECTOR_SCRIPT" 2>/dev/null || true)"

    assert_contains "$script_text" "trap 'cleanup_scratch_database' EXIT" \
        "detector should cleanup on normal exit"
    assert_contains "$script_text" "trap 'cleanup_scratch_database; exit 130' INT" \
        "detector should cleanup on interrupt"
    assert_contains "$script_text" "trap 'cleanup_scratch_database; exit 143' TERM" \
        "detector should cleanup on termination"
    assert_output_order "$script_text" "trap 'cleanup_scratch_database' EXIT" "CREATE DATABASE" \
        "detector should install normal-exit cleanup before creating scratch database"
    assert_output_order "$script_text" "trap 'cleanup_scratch_database; exit 130' INT" "CREATE DATABASE" \
        "detector should install interrupt cleanup before creating scratch database"
}

main() {
    echo "=== probe_local_schema_drift.sh tests ==="
    echo ""

    test_identical_schema_exits_zero_and_reports_clean
    test_missing_target_column_fails_and_names_column
    test_unexpected_target_column_fails_and_names_column
    test_target_only_table_is_informational
    test_reference_value_agreement_exits_zero_and_queries_both_databases
    test_legacy_shared_minimum_value_drift_fails_and_names_expected_and_found
    test_duplicate_active_target_reference_rows_are_fatal
    test_duplicate_active_oracle_reference_rows_are_fatal
    test_missing_target_reference_row_fails_with_missing_row_classification
    test_oracle_reference_value_query_failure_is_distinct_and_not_clean
    test_empty_oracle_reference_values_are_fatal_and_not_clean
    test_target_reference_query_failure_still_reports_column_drift
    test_multiple_column_differences_are_deterministic_and_complete
    test_oracle_build_failure_is_distinct_and_not_clean
    test_cleanup_uses_per_invocation_scratch_database_name
    test_cleanup_trap_is_installed_before_scratch_database_creation

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
