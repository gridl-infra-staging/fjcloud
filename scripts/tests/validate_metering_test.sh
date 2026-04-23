#!/usr/bin/env bash
# Tests for scripts/validate-metering.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

write_mock_psql() {
    local mock_path="$1"
    cat > "$mock_path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

mode="${VALIDATE_METERING_MODE:-pass}"
sql=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-c" ]; then
        sql="$2"
        break
    fi
    shift
 done

if [[ "$sql" == *"SELECT COUNT(*) FROM usage_records"* ]]; then
    echo "10"
elif [[ "$sql" == *"usage_daily WHERE aggregated_at >="* && "$sql" == *"48 hours"* ]]; then
    if [ "$mode" = "stale" ]; then
        echo "0"
    else
        echo "5"
    fi
elif [[ "$sql" == *"MAX(created_at)"* ]]; then
    echo "2026-03-04 00:00:00+00"
elif [[ "$sql" == *"SELECT COUNT(*) FROM usage_daily"* ]]; then
    echo "8"
elif [[ "$sql" == *"MAX(aggregated_at)"* ]]; then
    echo "2026-03-04 00:10:00+00"
elif [[ "$sql" == *"INNER JOIN usage_daily"* ]]; then
    echo "2"
else
    echo "0"
fi
exit 0
MOCK
    chmod +x "$mock_path"
}

test_validate_metering_fails_when_db_url_missing() {
    local output exit_code
    output="$(env -u DATABASE_URL -u INTEGRATION_DB_URL bash "$REPO_ROOT/scripts/validate-metering.sh" 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-metering should fail when no DB URL is set"
    assert_valid_json "$output" "validate-metering missing-db output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-metering missing-db JSON should report passed=false"
    assert_contains "$output" "db_url_missing" "validate-metering missing-db output should include db_url_missing reason"
}

test_validate_metering_passes_with_mocked_fresh_data() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    write_mock_psql "$mock_dir/psql"

    local output exit_code
    output="$(VALIDATE_METERING_MODE=pass INTEGRATION_DB_URL='postgres://localhost/test' PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-metering.sh" 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validate-metering should pass with healthy mocked data"
    assert_valid_json "$output" "validate-metering pass output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "validate-metering pass JSON should report passed=true"
}

test_validate_metering_fails_when_rollup_stale() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    write_mock_psql "$mock_dir/psql"

    local output exit_code
    output="$(VALIDATE_METERING_MODE=stale INTEGRATION_DB_URL='postgres://localhost/test' PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-metering.sh" 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-metering should fail when rollup data is stale"
    assert_valid_json "$output" "validate-metering stale output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-metering stale JSON should report passed=false"
    assert_contains "$output" "rollup_stale" "validate-metering stale output should include rollup_stale reason"
}

echo "=== validate-metering.sh tests ==="
test_validate_metering_fails_when_db_url_missing
test_validate_metering_passes_with_mocked_fresh_data
test_validate_metering_fails_when_rollup_stale

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
