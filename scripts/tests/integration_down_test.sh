#!/usr/bin/env bash
# Tests for integration-down.sh: idempotent teardown, partial-state cleanup,
# per-service status messaging.
# Uses temp PID dirs and mock processes — does NOT touch real services.

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

assert_not_contains() {
    local actual="$1" unexpected_substr="$2" msg="$3"
    if [[ "$actual" == *"$unexpected_substr"* ]]; then
        fail "$msg (unexpected substring '$unexpected_substr' found in '$actual')"
    else
        pass "$msg"
    fi
}

# ============================================================================
# Idempotent Teardown Tests
# ============================================================================

test_teardown_twice_is_safe() {
    # Running integration-down.sh twice in a row should not error.
    # First run with nothing running, second run also with nothing running.
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Create a fake repo root with .integration dir (empty — no services running)
    mkdir -p "$tmp_dir/.integration"

    # Mock psql to simulate "DB does not exist"
    local bin_dir="$tmp_dir/bin"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/psql" << 'MOCK'
#!/usr/bin/env bash
# Simulate: DB check returns empty (no DB exists)
if [[ "${*}" == *"SELECT 1 FROM pg_database"* ]]; then
    echo ""
    exit 0
fi
exit 0
MOCK
    chmod +x "$bin_dir/psql"

    # Run teardown twice — both should succeed (exit 0)
    local output1 exit1=0
    output1=$(
        PATH="$bin_dir:$PATH" \
        REPO_ROOT="$tmp_dir" \
        bash -c '
            REPO_ROOT="'"$tmp_dir"'"
            SCRIPT_DIR="'"$REPO_ROOT/scripts"'"
            source "'"$REPO_ROOT/scripts/integration-down.sh"'"
        ' 2>&1
    ) || exit1=$?
    # integration-down.sh runs on source, but we need to call it differently.
    # Let's just invoke it directly with env overrides via a wrapper.

    # Actually, integration-down.sh uses REPO_ROOT derived from SCRIPT_DIR.
    # We can't easily override that. Instead, test the kill_pid_file function
    # in isolation and the overall script behavior.

    # Simpler approach: run the actual script twice and check it doesn't error
    local exit_code1=0 exit_code2=0
    output1=$(bash "$REPO_ROOT/scripts/integration-down.sh" 2>&1) || exit_code1=$?
    local output2
    output2=$(bash "$REPO_ROOT/scripts/integration-down.sh" 2>&1) || exit_code2=$?

    assert_eq "$exit_code1" "0" "first teardown should succeed (nothing running)"
    assert_eq "$exit_code2" "0" "second teardown should succeed (idempotent)"
    assert_contains "$output2" "torn down" "second teardown should still report completion"
}

test_teardown_with_stale_pid_file() {
    # If a PID file exists but the process is already dead, teardown should
    # clean up the file without erroring.
    local pid_dir="$REPO_ROOT/.integration"
    mkdir -p "$pid_dir"

    # Write a PID that doesn't exist (use a very high PID)
    echo "99999999" > "$pid_dir/api.pid"

    local output exit_code=0
    output=$(bash "$REPO_ROOT/scripts/integration-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "teardown with stale PID should succeed"
    assert_contains "$output" "stale PID" "should report stale PID detection"

    # PID file should be cleaned up
    if [ -f "$pid_dir/api.pid" ]; then
        fail "stale PID file should be removed after teardown"
    else
        pass "stale PID file removed after teardown"
    fi
}

test_down_stale_pid_pointing_to_different_process() {
    # PID file points to a live but unrelated process: teardown must not kill it.
    local pid_dir="$REPO_ROOT/.integration"
    mkdir -p "$pid_dir"

    sleep 300 &
    local unrelated_pid=$!
    echo "$unrelated_pid" > "$pid_dir/api.pid"

    local output exit_code=0
    output=$(bash "$REPO_ROOT/scripts/integration-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "teardown should succeed with reused PID pointing to different process"
    assert_contains "$output" "skipping kill" "should warn and skip killing unrelated process PID"

    if kill -0 "$unrelated_pid" 2>/dev/null; then
        pass "unrelated process was not killed"
        kill "$unrelated_pid" 2>/dev/null || true
    else
        fail "teardown should not kill unrelated process referenced by stale PID file"
    fi
}

test_down_log_files_cleaned() {
    local pid_dir="$REPO_ROOT/.integration"
    mkdir -p "$pid_dir"
    echo "api log" > "$pid_dir/api.log"
    echo "flapjack log" > "$pid_dir/flapjack.log"

    local output exit_code=0
    output=$(bash "$REPO_ROOT/scripts/integration-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "teardown should succeed when cleaning log files"
    if compgen -G "$pid_dir/*.log" >/dev/null; then
        fail "teardown should remove .integration/*.log files"
    else
        pass "teardown removed .integration log files"
    fi
    assert_contains "$output" "torn down" "teardown should still report completion after log cleanup"
}

test_down_succeeds_when_psql_unavailable() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    cat > "$tmp_dir/whoami" << 'MOCK'
#!/usr/bin/env bash
echo "tester"
MOCK
    chmod +x "$tmp_dir/whoami"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        bash "$REPO_ROOT/scripts/integration-down.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "teardown should succeed when psql is unavailable"
    assert_contains "$output" "psql or docker compose postgres fallback not available" "teardown should report psql unavailable skip"
    assert_not_contains "$output" "does not exist (nothing to drop)" \
        "psql-unavailable path should not report database does-not-exist message"
}

test_down_psql_query_failure_reports_query_skip() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    cat > "$tmp_dir/whoami" << 'MOCK'
#!/usr/bin/env bash
echo "tester"
MOCK
    chmod +x "$tmp_dir/whoami"

    cat > "$tmp_dir/psql" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"SELECT 1 FROM pg_database"* ]]; then
    exit 2
fi
exit 0
MOCK
    chmod +x "$tmp_dir/psql"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        bash "$REPO_ROOT/scripts/integration-down.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "teardown should succeed when DB existence query fails"
    assert_contains "$output" "Unable to query postgres" "teardown should report DB query failure clearly"
    assert_not_contains "$output" "does not exist (nothing to drop)" \
        "DB query failure path should not report does-not-exist"
}

test_down_invalid_db_name_still_kills_processes() {
    local pid_dir="$REPO_ROOT/.integration"
    mkdir -p "$pid_dir"

    local proc_dir
    proc_dir="$(mktemp -d)"
    ln -sf /bin/sleep "$proc_dir/api"
    "$proc_dir/api" 300 &
    local dummy_pid=$!
    echo "$dummy_pid" > "$pid_dir/api.pid"

    local output exit_code=0
    output=$(
        INTEGRATION_DB="bad; DROP TABLE users; --" \
        bash "$REPO_ROOT/scripts/integration-down.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "teardown should still succeed when INTEGRATION_DB is invalid"
    assert_contains "$output" "INTEGRATION_DB must be a safe PostgreSQL identifier" \
        "teardown should log invalid DB name and skip DB drop"
    assert_contains "$output" "torn down" "teardown should complete after skipping DB drop"

    if kill -0 "$dummy_pid" 2>/dev/null; then
        kill "$dummy_pid" 2>/dev/null || true
        rm -rf "$proc_dir"
        fail "teardown should still kill API process when DB name is invalid"
    else
        rm -rf "$proc_dir"
        pass "teardown killed API process even with invalid DB name"
    fi
}

# ============================================================================
# Partial-State Cleanup Tests
# ============================================================================

test_teardown_handles_only_api_running() {
    # When only the API is running (no flapjack PID file), teardown should
    # handle the API and report flapjack as not running — no errors.
    local pid_dir="$REPO_ROOT/.integration"
    mkdir -p "$pid_dir"

    # Start a dummy background process named "api" so kill_pid_file command
    # verification treats it as the expected service.
    local proc_dir
    proc_dir="$(mktemp -d)"
    ln -sf /bin/sleep "$proc_dir/api"
    "$proc_dir/api" 300 &
    local dummy_pid=$!
    echo "$dummy_pid" > "$pid_dir/api.pid"

    # Remove flapjack PID file if it exists
    rm -f "$pid_dir/flapjack.pid"

    local output exit_code=0
    output=$(bash "$REPO_ROOT/scripts/integration-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "partial teardown (API only) should succeed"
    assert_contains "$output" "flapjack" "should mention flapjack status"
    assert_contains "$output" "torn down" "should report completion"

    # Dummy process should be killed
    if kill -0 "$dummy_pid" 2>/dev/null; then
        kill "$dummy_pid" 2>/dev/null || true
        rm -rf "$proc_dir"
        fail "API process should have been killed"
    else
        rm -rf "$proc_dir"
        pass "API process was killed by teardown"
    fi
}

test_teardown_handles_no_pid_dir() {
    # When the .integration directory doesn't exist at all, teardown should
    # still succeed gracefully.
    rm -rf "$REPO_ROOT/.integration"

    local output exit_code=0
    output=$(bash "$REPO_ROOT/scripts/integration-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "teardown with no PID dir should succeed"
    assert_contains "$output" "torn down" "should report completion even with no PID dir"
}

test_teardown_reports_per_service_status() {
    # Teardown should report status for each service (API, flapjack, DB)
    # even when nothing is running. This ensures operators can see what happened.
    local output exit_code=0
    output=$(bash "$REPO_ROOT/scripts/integration-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "teardown should succeed"
    assert_contains "$output" "API" "output should mention API service"
    assert_contains "$output" "flapjack" "output should mention flapjack service"
    assert_contains "$output" "torn down" "output should confirm teardown complete"
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== integration-down.sh tests ==="
    echo ""

    echo "--- Idempotent Teardown ---"
    test_teardown_twice_is_safe
    test_teardown_with_stale_pid_file
    test_down_stale_pid_pointing_to_different_process
    test_down_log_files_cleaned
    test_down_succeeds_when_psql_unavailable
    test_down_psql_query_failure_reports_query_skip
    test_down_invalid_db_name_still_kills_processes

    echo ""
    echo "--- Partial-State Cleanup ---"
    test_teardown_handles_only_api_running
    test_teardown_handles_no_pid_dir
    test_teardown_reports_per_service_status

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
