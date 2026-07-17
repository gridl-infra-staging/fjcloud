#!/usr/bin/env bash
# Tests for scripts/lib/metering_checks.sh: Metering validation check functions.
# Validates script logic without requiring real Postgres — uses mock psql
# responses in subshells and controlled env vars.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$msg (expected='$expected' actual='$actual')"
    else
        pass "$msg"
    fi
}

assert_contains() {
    local actual="$1" expected_substr="$2" msg="$3"
    if [[ "$actual" != *"$expected_substr"* ]]; then
        fail "$msg (expected substring '$expected_substr' in '$actual')"
    else
        pass "$msg"
    fi
}

# ============================================================================
# check_usage_records_populated tests
# ============================================================================

test_check_usage_records_populated_fails_when_empty() {
    # Mock psql that returns 0 rows
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "0"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_usage_records_populated
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "check_usage_records_populated should fail when table has 0 rows (gate on)"
    assert_contains "$output" "usage_records" "output should mention usage_records table"
}

test_check_usage_records_populated_emits_reason_code_empty_table() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "0"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_usage_records_populated
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "check_usage_records_populated should fail when table has 0 rows (gate on)"
    assert_contains "$output" "REASON: usage_records_empty" "failure output should include usage_records_empty reason code"
}

test_check_usage_records_populated_passes_when_rows_exist() {
    # Mock psql that returns >0 rows
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "42"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_usage_records_populated
        echo 'POPULATED_OK'
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "check_usage_records_populated should pass when rows exist"
    assert_contains "$output" "POPULATED_OK" "execution should continue after passing check"
}

test_check_usage_records_populated_skips_when_gate_off() {
    # Mock psql that returns 0 rows — but gate is off
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "0"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(unset BACKEND_LIVE_GATE; INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        unset BACKEND_LIVE_GATE
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_usage_records_populated
        echo 'SKIPPED_OK'
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "check_usage_records_populated should skip when gate is off"
    assert_contains "$output" "SKIPPED_OK" "execution should continue after skip"
}

test_check_usage_records_populated_fails_when_no_db_url() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        unset INTEGRATION_DB_URL
        unset DATABASE_URL
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_usage_records_populated
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_usage_records_populated should fail when no DB URL (gate on)"
    assert_contains "$output" "database" "output should mention database connection"
}

test_check_usage_records_populated_emits_reason_code_db_url_missing() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        unset INTEGRATION_DB_URL
        unset DATABASE_URL
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_usage_records_populated
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_usage_records_populated should fail when no DB URL (gate on)"
    assert_contains "$output" "REASON: db_url_missing" "failure output should include db_url_missing reason code"
}

test_db_connection_timeout_produces_specific_reason() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "psql: error: could not connect to server: Connection refused" >&2
exit 2
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_usage_records_populated
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" \
        "check_usage_records_populated should fail on psql connection timeout/error"
    assert_contains "$output" "REASON: db_connection_timeout" \
        "connection failure should include db_connection_timeout reason code"
}

test_db_query_timeout_produces_specific_reason() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR: canceling statement due to statement timeout" >&2
exit 1
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_usage_records_populated
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" \
        "check_usage_records_populated should fail when query hits statement timeout"
    assert_contains "$output" "REASON: db_query_timeout" \
        "statement timeout should include db_query_timeout reason code"
}

test_db_unknown_query_error_produces_generic_query_failure_reason() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR: relation \"usage_records\" does not exist" >&2
exit 1
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_usage_records_populated
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" \
        "check_usage_records_populated should fail on non-timeout SQL errors"
    assert_contains "$output" "REASON: db_query_failed" \
        "non-timeout SQL errors should include db_query_failed reason code"
}

test_check_usage_records_populated_emits_timeout_reason() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
exec sleep 60
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 GATE_INNER_TIMEOUT_SEC=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_usage_records_populated
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "124" \
        "check_usage_records_populated should return 124 when inner timeout fires"
    assert_contains "$output" "REASON: db_connection_timeout" \
        "usage_records inner timeout should emit db_connection_timeout"
}

# ============================================================================
# check_rollup_current tests
# ============================================================================

test_check_rollup_current_fails_when_stale() {
    # Mock psql that returns an old timestamp (>48h ago)
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
# Return 0 rows within the freshness window
echo "0"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_rollup_current
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "check_rollup_current should fail when rollup is stale (gate on)"
    assert_contains "$output" "usage_daily" "output should mention usage_daily table"
}

test_check_rollup_current_emits_reason_code_stale() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "0"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_rollup_current
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "check_rollup_current should fail when rollup is stale (gate on)"
    assert_contains "$output" "REASON: rollup_stale" "failure output should include rollup_stale reason code"
}

test_check_rollup_current_passes_when_fresh() {
    # Mock psql that returns a recent timestamp
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
# Return 1 row within the freshness window
echo "1"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_rollup_current
        echo 'ROLLUP_OK'
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "check_rollup_current should pass when rollup is fresh"
    assert_contains "$output" "ROLLUP_OK" "execution should continue after passing check"
}

test_check_rollup_current_skips_when_gate_off() {
    # Mock psql returning stale — but gate is off
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "0"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(unset BACKEND_LIVE_GATE; INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        unset BACKEND_LIVE_GATE
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_rollup_current
        echo 'SKIPPED_OK'
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "check_rollup_current should skip when gate is off"
    assert_contains "$output" "SKIPPED_OK" "execution should continue after skip"
}

test_check_rollup_current_fails_when_no_db_url() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        unset INTEGRATION_DB_URL
        unset DATABASE_URL
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_rollup_current
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_rollup_current should fail when no DB URL (gate on)"
    assert_contains "$output" "database" "output should mention database connection"
}

test_db_connection_timeout_for_rollup_check() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "psql: error: timeout expired" >&2
exit 2
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_rollup_current
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" \
        "check_rollup_current should fail on psql connection timeout/error"
    assert_contains "$output" "REASON: db_connection_timeout" \
        "rollup connection failure should include db_connection_timeout reason code"
}

test_check_rollup_current_emits_timeout_reason() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
exec sleep 60
MOCK
    chmod +x "$mock_dir/psql"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 GATE_INNER_TIMEOUT_SEC=1 INTEGRATION_DB_URL="postgres://localhost/test" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/metering_checks.sh'
        check_rollup_current
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "124" \
        "check_rollup_current should return 124 when inner timeout fires"
    assert_contains "$output" "REASON: db_connection_timeout" \
        "rollup inner timeout should emit db_connection_timeout"
}

# ============================================================================
# Run tests
# ============================================================================

echo "=== metering_checks.sh tests ==="
echo ""
echo "--- check_usage_records_populated ---"
test_check_usage_records_populated_fails_when_empty
test_check_usage_records_populated_emits_reason_code_empty_table
test_check_usage_records_populated_passes_when_rows_exist
test_check_usage_records_populated_skips_when_gate_off
test_check_usage_records_populated_fails_when_no_db_url
test_check_usage_records_populated_emits_reason_code_db_url_missing
test_db_connection_timeout_produces_specific_reason
test_db_query_timeout_produces_specific_reason
test_db_unknown_query_error_produces_generic_query_failure_reason
test_check_usage_records_populated_emits_timeout_reason
echo ""
echo "--- check_rollup_current ---"
test_check_rollup_current_fails_when_stale
test_check_rollup_current_emits_reason_code_stale
test_check_rollup_current_passes_when_fresh
test_check_rollup_current_skips_when_gate_off
test_check_rollup_current_fails_when_no_db_url
test_db_connection_timeout_for_rollup_check
test_check_rollup_current_emits_timeout_reason
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
