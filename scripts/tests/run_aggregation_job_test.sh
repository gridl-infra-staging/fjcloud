#!/usr/bin/env bash
# Tests for scripts/run-aggregation-job.sh: default date, explicit date,
# DATABASE_URL requirement, cargo env vars, macOS/GNU date fallback.
# Uses mock binaries — does NOT touch real services or databases.

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
# shellcheck source=lib/local_dev_test_state.sh
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"

LOCAL_DEV_TEST_DB_URL="postgres://local-test:local-pass@localhost:5432/local_dev_test"

setup_aggregation_test_state() {
    local tmp_dir="$1"
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    write_local_dev_env_file "$REPO_ROOT/.env.local" "$LOCAL_DEV_TEST_DB_URL"
}

restore_aggregation_test_state() {
    restore_repo_path "$REPO_ROOT/.env.local" "${LOCAL_DEV_ENV_BACKUP:-}"
    restore_repo_path "$REPO_ROOT/.local" "${LOCAL_DEV_RUNTIME_BACKUP:-}"
    LOCAL_DEV_ENV_BACKUP=""
    LOCAL_DEV_RUNTIME_BACKUP=""
}

write_mock_script() {
    local path="$1" body="$2"
    cat > "$path" << MOCK
#!/usr/bin/env bash
$body
MOCK
    chmod +x "$path"
}

# ============================================================================
# Tests
# ============================================================================

test_default_date_is_yesterday() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_aggregation_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_aggregation_test_state "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"

    # Mock cargo: log TARGET_DATE env var.
    write_mock_script "$tmp_dir/bin/cargo" \
        'echo "TARGET_DATE=${TARGET_DATE:-} cargo $@" >> "'"$call_log"'"'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/run-aggregation-job.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed without a date argument"

    # Compute yesterday's date the same way the script does (macOS or GNU).
    local expected_date
    expected_date="$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d)"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "TARGET_DATE=$expected_date" \
        "should default TARGET_DATE to yesterday ($expected_date)"
    assert_contains "$output" "Running aggregation for $expected_date" \
        "should log the target date"
}

test_explicit_date_argument_passed_through() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_aggregation_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_aggregation_test_state "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"

    write_mock_script "$tmp_dir/bin/cargo" \
        'echo "TARGET_DATE=${TARGET_DATE:-} cargo $@" >> "'"$call_log"'"'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/run-aggregation-job.sh" "2026-03-27" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed with explicit date argument"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "TARGET_DATE=2026-03-27" \
        "should pass the explicit date argument as TARGET_DATE"
    assert_contains "$output" "Running aggregation for 2026-03-27" \
        "should log the explicit target date"
}

test_database_url_is_required() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_aggregation_test_state; rm -rf "'"$tmp_dir"'"' RETURN

    # Set up env backup and runtime backup, but write .env.local WITHOUT DATABASE_URL.
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
JWT_SECRET=test-jwt-secret
ADMIN_KEY=test-admin-key
EOF

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/cargo" \
        'echo "cargo $@" >> "'"$tmp_dir"'/calls.log"'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/run-aggregation-job.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when DATABASE_URL is missing"
    assert_contains "$output" "DATABASE_URL is required" \
        "should report that DATABASE_URL is missing"
}

test_correct_env_vars_passed_to_cargo() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_aggregation_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_aggregation_test_state "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"

    # Log both DATABASE_URL and TARGET_DATE that cargo receives.
    write_mock_script "$tmp_dir/bin/cargo" \
        'echo "DATABASE_URL=${DATABASE_URL:-} TARGET_DATE=${TARGET_DATE:-} cargo $@" >> "'"$call_log"'"'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/run-aggregation-job.sh" "2026-01-15" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed with valid env"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "DATABASE_URL=$LOCAL_DEV_TEST_DB_URL" \
        "should pass DATABASE_URL to cargo run"
    assert_contains "$calls" "TARGET_DATE=2026-01-15" \
        "should pass TARGET_DATE to cargo run"
    assert_contains "$calls" "cargo run --manifest-path" \
        "should invoke cargo run with --manifest-path"
    assert_contains "$calls" "-p aggregation-job" \
        "should run the aggregation-job crate"
}

test_macos_vs_gnu_date_fallback() {
    # This test verifies the date command fallback logic produces a valid
    # YYYY-MM-DD date regardless of whether macOS date or GNU date is used.
    # We can't easily mock the date command itself (it's used before PATH mocks
    # take effect), so we verify the output format is correct.
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_aggregation_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_aggregation_test_state "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"

    write_mock_script "$tmp_dir/bin/cargo" \
        'echo "TARGET_DATE=${TARGET_DATE:-}" >> "'"$call_log"'"'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/run-aggregation-job.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed using the platform's date command"

    local target_date_line
    target_date_line=$(cat "$call_log" 2>/dev/null || true)
    # Extract the date value from the logged line.
    local date_value="${target_date_line#TARGET_DATE=}"

    # Verify YYYY-MM-DD format.
    if [[ "$date_value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        pass "date fallback produces valid YYYY-MM-DD format ($date_value)"
    else
        fail "date fallback did not produce YYYY-MM-DD format (got '$date_value')"
    fi
}

test_completion_message() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_aggregation_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_aggregation_test_state "$tmp_dir"

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/cargo" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/run-aggregation-job.sh" "2026-03-27" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed"
    assert_contains "$output" "Aggregation complete for 2026-03-27" \
        "should log completion message with the target date"
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== run-aggregation-job.sh tests ==="
    echo ""

    test_default_date_is_yesterday
    test_explicit_date_argument_passed_through
    test_database_url_is_required
    test_correct_env_vars_passed_to_cargo
    test_macos_vs_gnu_date_fallback
    test_completion_message

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
