#!/usr/bin/env bash
# Tests for scripts/local-dev-down.sh: flapjack teardown, docker compose down,
# --clean flag, idempotent behavior.
# Uses mock docker and temp PID files — does NOT touch real services.

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

setup_local_dev_runtime_state() {
    local tmp_dir="$1"
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
}

restore_local_dev_runtime_state() {
    restore_repo_path "$REPO_ROOT/.local" "${LOCAL_DEV_RUNTIME_BACKUP:-}"
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

test_kills_flapjack_via_pid_file() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local pid_dir="$REPO_ROOT/.local"
    mkdir -p "$pid_dir"

    # Copy sleep binary as "flapjack" so ps comm= shows "flapjack"
    cp "$(command -v sleep)" "$tmp_dir/flapjack"
    (
        nohup "$tmp_dir/flapjack" 300 >/dev/null 2>&1 &
        echo $! > "$tmp_dir/flapjack_test.pid"
    )
    local fj_pid
    fj_pid=$(cat "$tmp_dir/flapjack_test.pid")
    echo "$fj_pid" > "$pid_dir/flapjack.pid"

    # Mock docker
    write_mock_script "$tmp_dir/docker" 'exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" bash "$REPO_ROOT/scripts/local-dev-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "local-dev-down should succeed"

    if kill -0 "$fj_pid" 2>/dev/null; then
        kill "$fj_pid" 2>/dev/null || true
        fail "flapjack process should have been killed"
    else
        pass "flapjack process was killed via PID file"
    fi

    if [ -f "$pid_dir/flapjack.pid" ]; then
        rm -f "$pid_dir/flapjack.pid"
        fail "flapjack PID file should have been removed"
    else
        pass "flapjack PID file was removed"
    fi

    # Clean up
    rm -rf "$pid_dir" 2>/dev/null || true
}

test_runs_docker_compose_down() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    write_mock_script "$tmp_dir/docker" \
        'echo "$@" >> "'"$tmp_dir"'/docker_calls.log"; exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" bash "$REPO_ROOT/scripts/local-dev-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "local-dev-down should succeed"

    local docker_args
    docker_args=$(cat "$tmp_dir/docker_calls.log" 2>/dev/null || true)
    assert_contains "$docker_args" "compose down" \
        "should call docker compose down"
}

test_clean_flag_adds_volume_removal() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    write_mock_script "$tmp_dir/docker" \
        'echo "$@" >> "'"$tmp_dir"'/docker_calls.log"; exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" bash "$REPO_ROOT/scripts/local-dev-down.sh" --clean 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "local-dev-down --clean should succeed"

    local docker_args
    docker_args=$(cat "$tmp_dir/docker_calls.log" 2>/dev/null || true)
    assert_contains "$docker_args" "-v" \
        "--clean should add -v to docker compose down"
}

test_removes_log_files_and_pid_directory() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local pid_dir="$REPO_ROOT/.local"
    mkdir -p "$pid_dir"
    echo "test log" > "$pid_dir/flapjack.log"

    write_mock_script "$tmp_dir/docker" 'exit 0'

    PATH="$tmp_dir:$PATH" bash "$REPO_ROOT/scripts/local-dev-down.sh" 2>&1 >/dev/null

    if [ -f "$pid_dir/flapjack.log" ]; then
        rm -f "$pid_dir/flapjack.log"
        fail "log files should be removed"
    else
        pass "log files removed from .local/"
    fi

    # .local/ dir should be removed if empty
    if [ -d "$pid_dir" ]; then
        rmdir "$pid_dir" 2>/dev/null || true
        fail ".local/ directory should be removed when empty"
    else
        pass ".local/ directory removed when empty"
    fi
}

test_idempotent_when_nothing_running() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    write_mock_script "$tmp_dir/docker" 'exit 0'

    # Run twice — both should succeed
    local exit1=0 exit2=0
    PATH="$tmp_dir:$PATH" bash "$REPO_ROOT/scripts/local-dev-down.sh" 2>&1 >/dev/null || exit1=$?
    PATH="$tmp_dir:$PATH" bash "$REPO_ROOT/scripts/local-dev-down.sh" 2>&1 >/dev/null || exit2=$?

    assert_eq "$exit1" "0" "first teardown should succeed (nothing running)"
    assert_eq "$exit2" "0" "second teardown should succeed (idempotent)"
}

test_cleans_up_metering_agent_pid_files() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local pid_dir="$REPO_ROOT/.local"
    mkdir -p "$pid_dir"

    # Create fake metering-agent PID files pointing to non-running processes.
    # Use PID 99999 which is almost certainly not running.
    echo "99999" > "$pid_dir/metering-agent-us-east-1.pid"
    echo "99998" > "$pid_dir/metering-agent-eu-west-1.pid"
    echo "99997" > "$pid_dir/metering-agent-eu-central-1.pid"
    # Also create a log file for each to verify full cleanup.
    echo "test log" > "$pid_dir/metering-agent-us-east-1.log"
    echo "test log" > "$pid_dir/metering-agent-eu-west-1.log"

    write_mock_script "$tmp_dir/docker" 'exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" bash "$REPO_ROOT/scripts/local-dev-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed cleaning up metering-agent PID files"

    # Verify all metering-agent PID files are removed.
    if [ -f "$pid_dir/metering-agent-us-east-1.pid" ]; then
        fail "metering-agent-us-east-1.pid should be removed"
    else
        pass "metering-agent-us-east-1.pid was removed"
    fi

    if [ -f "$pid_dir/metering-agent-eu-west-1.pid" ]; then
        fail "metering-agent-eu-west-1.pid should be removed"
    else
        pass "metering-agent-eu-west-1.pid was removed"
    fi

    if [ -f "$pid_dir/metering-agent-eu-central-1.pid" ]; then
        fail "metering-agent-eu-central-1.pid should be removed"
    else
        pass "metering-agent-eu-central-1.pid was removed"
    fi

    # Log files should also be cleaned up (the script rm -f *.log).
    if [ -f "$pid_dir/metering-agent-us-east-1.log" ]; then
        fail "metering-agent log files should be removed"
    else
        pass "metering-agent log files were removed"
    fi

    rm -rf "$pid_dir" 2>/dev/null || true
}

test_cleans_up_multi_region_flapjack_pid_files() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local pid_dir="$REPO_ROOT/.local"
    mkdir -p "$pid_dir"

    # Create fake multi-region flapjack PID files (non-running PIDs).
    echo "99996" > "$pid_dir/flapjack-us-east-1.pid"
    echo "99995" > "$pid_dir/flapjack-eu-west-1.pid"
    echo "99994" > "$pid_dir/flapjack-eu-central-1.pid"

    write_mock_script "$tmp_dir/docker" 'exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" bash "$REPO_ROOT/scripts/local-dev-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed cleaning up multi-region flapjack PID files"

    if [ -f "$pid_dir/flapjack-us-east-1.pid" ]; then
        fail "flapjack-us-east-1.pid should be removed"
    else
        pass "flapjack-us-east-1.pid was removed"
    fi

    if [ -f "$pid_dir/flapjack-eu-west-1.pid" ]; then
        fail "flapjack-eu-west-1.pid should be removed"
    else
        pass "flapjack-eu-west-1.pid was removed"
    fi

    if [ -f "$pid_dir/flapjack-eu-central-1.pid" ]; then
        fail "flapjack-eu-central-1.pid should be removed"
    else
        pass "flapjack-eu-central-1.pid was removed"
    fi

    rm -rf "$pid_dir" 2>/dev/null || true
}

test_kills_running_metering_agent_via_pid_file() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local pid_dir="$REPO_ROOT/.local"
    mkdir -p "$pid_dir"

    # Copy sleep binary as "metering-agent" so ps comm= matches the expected_cmd.
    cp "$(command -v sleep)" "$tmp_dir/metering-agent"
    (
        nohup "$tmp_dir/metering-agent" 300 >/dev/null 2>&1 &
        echo $! > "$tmp_dir/metering_test.pid"
    )
    local agent_pid
    agent_pid=$(cat "$tmp_dir/metering_test.pid")
    echo "$agent_pid" > "$pid_dir/metering-agent-us-east-1.pid"

    write_mock_script "$tmp_dir/docker" 'exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" bash "$REPO_ROOT/scripts/local-dev-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "local-dev-down should succeed"

    if kill -0 "$agent_pid" 2>/dev/null; then
        kill "$agent_pid" 2>/dev/null || true
        fail "metering-agent process should have been killed"
    else
        pass "metering-agent process was killed via PID file"
    fi

    if [ -f "$pid_dir/metering-agent-us-east-1.pid" ]; then
        rm -f "$pid_dir/metering-agent-us-east-1.pid"
        fail "metering-agent PID file should have been removed"
    else
        pass "metering-agent PID file was removed after kill"
    fi

    rm -rf "$pid_dir" 2>/dev/null || true
}

test_kills_local_demo_api_and_web_pid_files() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local pid_dir="$REPO_ROOT/.local"
    mkdir -p "$pid_dir"

    cp "$(command -v sleep)" "$tmp_dir/cargo"
    cp "$(command -v sleep)" "$tmp_dir/node"
    (
        nohup "$tmp_dir/cargo" 300 >/dev/null 2>&1 &
        echo $! > "$tmp_dir/api_test.pid"
        nohup "$tmp_dir/node" 300 >/dev/null 2>&1 &
        echo $! > "$tmp_dir/web_test.pid"
    )
    local api_pid web_pid
    api_pid=$(cat "$tmp_dir/api_test.pid")
    web_pid=$(cat "$tmp_dir/web_test.pid")
    echo "$api_pid" > "$pid_dir/api.pid"
    echo "$web_pid" > "$pid_dir/web.pid"

    write_mock_script "$tmp_dir/docker" 'exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" bash "$REPO_ROOT/scripts/local-dev-down.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "local-dev-down should succeed for local demo PIDs"

    if kill -0 "$api_pid" 2>/dev/null; then
        kill "$api_pid" 2>/dev/null || true
        fail "local demo API process should have been killed"
    else
        pass "local demo API process was killed via PID file"
    fi

    if kill -0 "$web_pid" 2>/dev/null; then
        kill "$web_pid" 2>/dev/null || true
        fail "local demo web process should have been killed"
    else
        pass "local demo web process was killed via PID file"
    fi

    if [ -f "$pid_dir/api.pid" ] || [ -f "$pid_dir/web.pid" ]; then
        rm -f "$pid_dir/api.pid" "$pid_dir/web.pid"
        fail "local demo PID files should have been removed"
    else
        pass "local demo PID files were removed"
    fi

    rm -rf "$pid_dir" 2>/dev/null || true
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== local-dev-down.sh tests ==="
    echo ""

    test_kills_flapjack_via_pid_file
    test_runs_docker_compose_down
    test_clean_flag_adds_volume_removal
    test_removes_log_files_and_pid_directory
    test_idempotent_when_nothing_running
    test_cleans_up_metering_agent_pid_files
    test_cleans_up_multi_region_flapjack_pid_files
    test_kills_running_metering_agent_via_pid_file
    test_kills_local_demo_api_and_web_pid_files

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
