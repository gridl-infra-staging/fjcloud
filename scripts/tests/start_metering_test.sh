#!/usr/bin/env bash
# Tests for scripts/start-metering.sh: customer UUID lookup, single/multi-region
# mode, idempotent PID file handling, error paths.
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
MOCK_CUSTOMER_UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

setup_metering_test_state() {
    local tmp_dir="$1"
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    write_local_dev_env_file "$REPO_ROOT/.env.local" "$LOCAL_DEV_TEST_DB_URL"
}

restore_metering_test_state() {
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

# Standard mock bin setup for metering tests.
# psql returns the mock customer UUID, cargo logs its invocation.
setup_metering_mocks() {
    local mock_dir="$1" call_log="$2"

    # Mock psql: return the customer UUID for the shared-plan lookup query.
    write_mock_script "$mock_dir/psql" \
        'echo "psql $@" >> "'"$call_log"'"
echo "'"$MOCK_CUSTOMER_UUID"'"'

    # Mock cargo: log env vars and arguments instead of building/running.
    write_mock_script "$mock_dir/cargo" \
        'echo "DATABASE_URL=${DATABASE_URL:-} FLAPJACK_URL=${FLAPJACK_URL:-} FLAPJACK_API_KEY=${FLAPJACK_API_KEY:-} CUSTOMER_ID=${CUSTOMER_ID:-} NODE_ID=${NODE_ID:-} REGION=${REGION:-} SCRAPE_INTERVAL_SECS=${SCRAPE_INTERVAL_SECS:-} HEALTH_PORT=${HEALTH_PORT:-} cargo $@" >> "'"$call_log"'"
# Sleep briefly so the PID file is written before the process exits
sleep 0.2'

    # Mock docker: succeed on any compose command (used by psql fallback check).
    write_mock_script "$mock_dir/docker" \
        'echo "docker $@" >> "'"$call_log"'"; exit 0'

    # Mock nohup: run the command directly in background.
    write_mock_script "$mock_dir/nohup" \
        '"$@" &'

    # Mock curl: succeed (health checks).
    write_mock_script "$mock_dir/curl" \
        'echo "curl $@" >> "'"$call_log"'"; exit 0'

    # Mock kill: succeed (for idempotent PID checks).
    # Don't override kill — it's a shell builtin and we need it for real PID checks.
}

# ============================================================================
# Tests
# ============================================================================

test_single_region_passes_correct_env_vars() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_metering_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_metering_test_state "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_metering_mocks "$tmp_dir/bin" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/start-metering.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "single-region start should succeed"

    # Wait for the backgrounded nohup/cargo process to finish writing to the log.
    sleep 1

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)

    # Verify the cargo invocation includes the expected env vars.
    assert_contains "$calls" "DATABASE_URL=$LOCAL_DEV_TEST_DB_URL" \
        "should pass DATABASE_URL to cargo run"
    assert_contains "$calls" "FLAPJACK_URL=http://127.0.0.1:7700" \
        "single-region should default to flapjack on port 7700"
    assert_contains "$calls" "CUSTOMER_ID=$MOCK_CUSTOMER_UUID" \
        "should pass the looked-up customer UUID to cargo run"
    assert_contains "$calls" "REGION=us-east-1" \
        "single-region should default to us-east-1"
    assert_contains "$calls" "HEALTH_PORT=9091" \
        "single-region should use health port 9091"
    assert_contains "$calls" "SCRAPE_INTERVAL_SECS=30" \
        "should set a scrape interval"
    assert_contains "$calls" "cargo run --manifest-path" \
        "should invoke cargo run with --manifest-path"
    assert_contains "$calls" "-p metering-agent" \
        "should run the metering-agent crate"
}

test_customer_uuid_lookup_uses_psql_when_available() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_metering_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_metering_test_state "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_metering_mocks "$tmp_dir/bin" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/start-metering.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed with psql available"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "psql $LOCAL_DEV_TEST_DB_URL" \
        "should use host psql when available for customer UUID lookup"
    assert_contains "$output" "$MOCK_CUSTOMER_UUID" \
        "should log the found customer UUID"
}

test_customer_uuid_lookup_falls_back_to_docker_compose() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_metering_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_metering_test_state "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"

    # Set up mocks WITHOUT psql — force docker compose fallback.
    # No psql mock is created, so `command -v psql` will fail on systems
    # without psql. On systems WITH psql, the real psql can't connect to
    # the fake DATABASE_URL, so CUSTOMER_ID will be empty and the docker
    # fallback won't be reached. We skip this test if real psql is found.
    if command -v psql >/dev/null 2>&1; then
        pass "SKIP: real psql found on system — cannot force docker fallback"
        pass "SKIP: docker compose exec fallback"
        pass "SKIP: customer UUID via docker"
        return 0
    fi

    # Mock docker to return the customer UUID when exec'ing psql.
    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log"'"
if [[ "$*" == *"compose exec"*"psql"* ]]; then
    echo "'"$MOCK_CUSTOMER_UUID"'"
    exit 0
fi
exit 0'
    write_mock_script "$tmp_dir/bin/cargo" \
        'echo "CUSTOMER_ID=${CUSTOMER_ID:-} cargo $@" >> "'"$call_log"'"; sleep 0.2'
    write_mock_script "$tmp_dir/bin/nohup" '"$@" &'
    write_mock_script "$tmp_dir/bin/curl" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/start-metering.sh" 2>&1
    ) || exit_code=$?

    # Wait for backgrounded cargo to finish writing.
    sleep 1

    assert_eq "$exit_code" "0" "should succeed using docker compose psql fallback"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose exec" \
        "should fall back to docker compose exec for psql"
    assert_contains "$calls" "CUSTOMER_ID=$MOCK_CUSTOMER_UUID" \
        "should pass the customer UUID from docker compose psql to cargo"
}

test_multi_region_parses_flapjack_regions() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_metering_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_metering_test_state "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_metering_mocks "$tmp_dir/bin" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701 eu-central-1:7702" \
        bash "$REPO_ROOT/scripts/start-metering.sh" --multi-region 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "multi-region start should succeed"

    # Brief pause for backgrounded nohup processes to finish writing.
    sleep 0.5

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)

    # Verify each region gets its own agent with the correct Flapjack URL.
    assert_contains "$calls" "FLAPJACK_URL=http://127.0.0.1:7700" \
        "should start agent for us-east-1 on flapjack port 7700"
    assert_contains "$calls" "FLAPJACK_URL=http://127.0.0.1:7701" \
        "should start agent for eu-west-1 on flapjack port 7701"
    assert_contains "$calls" "FLAPJACK_URL=http://127.0.0.1:7702" \
        "should start agent for eu-central-1 on flapjack port 7702"

    assert_contains "$calls" "REGION=us-east-1" \
        "should set REGION=us-east-1 for first agent"
    assert_contains "$calls" "REGION=eu-west-1" \
        "should set REGION=eu-west-1 for second agent"
    assert_contains "$calls" "REGION=eu-central-1" \
        "should set REGION=eu-central-1 for third agent"
}

test_multi_region_health_ports_auto_derived() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_metering_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_metering_test_state "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_metering_mocks "$tmp_dir/bin" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701 eu-central-1:7702" \
        bash "$REPO_ROOT/scripts/start-metering.sh" --multi-region 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "multi-region start should succeed"

    sleep 0.5

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)

    # Health ports auto-derive starting at 9091: 9091, 9092, 9093.
    assert_contains "$calls" "HEALTH_PORT=9091" \
        "first region health port should be 9091"
    assert_contains "$calls" "HEALTH_PORT=9092" \
        "second region health port should be 9092"
    assert_contains "$calls" "HEALTH_PORT=9093" \
        "third region health port should be 9093"
}

test_idempotent_skips_running_process() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_metering_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_metering_test_state "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_metering_mocks "$tmp_dir/bin" "$call_log"

    # Pre-create a PID file pointing to a running process (our own shell).
    # The script checks kill -0 on the PID, so using $$ (current shell) works.
    local pid_dir="$REPO_ROOT/.local"
    mkdir -p "$pid_dir"
    echo "$$" > "$pid_dir/metering-agent-us-east-1.pid"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/start-metering.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed when agent is already running"
    assert_contains "$output" "already running" \
        "should report that the agent is already running"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    # cargo should NOT have been called because the PID file was valid.
    assert_not_contains "$calls" "cargo run" \
        "should not start a new cargo run when agent is already running"
}

test_fails_if_no_shared_customer_found() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_metering_test_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_metering_test_state "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"

    # Mock psql that returns empty output (no shared customer).
    write_mock_script "$tmp_dir/bin/psql" \
        'echo "psql $@" >> "'"$call_log"'"; echo ""'
    write_mock_script "$tmp_dir/bin/cargo" \
        'echo "cargo $@" >> "'"$call_log"'"; exit 0'
    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" '"$@" &'
    write_mock_script "$tmp_dir/bin/curl" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/start-metering.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when no shared customer is found"
    assert_contains "$output" "no shared customer found" \
        "should explain that seed_local.sh needs to be run first"
}

test_fails_if_database_url_missing() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_metering_test_state; rm -rf "'"$tmp_dir"'"' RETURN

    # Set up env backup and runtime backup, but write an .env.local WITHOUT DATABASE_URL.
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
JWT_SECRET=test-jwt-secret
ADMIN_KEY=test-admin-key
EOF

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/psql" 'exit 0'
    write_mock_script "$tmp_dir/bin/docker" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/start-metering.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when DATABASE_URL is missing"
    assert_contains "$output" "DATABASE_URL is required" \
        "should report that DATABASE_URL is missing"
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== start-metering.sh tests ==="
    echo ""

    test_single_region_passes_correct_env_vars
    test_customer_uuid_lookup_uses_psql_when_available
    test_customer_uuid_lookup_falls_back_to_docker_compose
    test_multi_region_parses_flapjack_regions
    test_multi_region_health_ports_auto_derived
    test_idempotent_skips_running_process
    test_fails_if_no_shared_customer_found
    test_fails_if_database_url_missing

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
