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
    LOCAL_DEV_TEST_REPO_ROOT="$(create_local_dev_fixture_repo_root "$tmp_dir")"
    LOCAL_DEV_COMPOSE_PROJECT_NAME="fjcloud_local_dev_down_$$_${RANDOM}"
}

restore_local_dev_runtime_state() {
    # Reap first: every caller's RETURN trap is
    # `restore_local_dev_runtime_state; rm -rf "$tmp_dir"`, and the fake service
    # binaries live in that directory. Killing before the directory is removed keeps
    # cleanup unconditional rather than contingent on the code under test having
    # killed them, which is the exact failure these tests exist to detect.
    reap_named_test_services
    LOCAL_DEV_TEST_REPO_ROOT=""
    LOCAL_DEV_COMPOSE_PROJECT_NAME=""
}

run_local_dev_down() {
    FJCLOUD_REPO_ROOT="$LOCAL_DEV_TEST_REPO_ROOT" \
    COMPOSE_PROJECT_NAME="$LOCAL_DEV_COMPOSE_PROJECT_NAME" \
        bash "$REPO_ROOT/scripts/local-dev-down.sh" "$@"
}

create_local_dev_down_script_checkout() {
    local checkout_root="$1"

    mkdir -p "$checkout_root/scripts/lib" "$checkout_root/web"
    cp "$REPO_ROOT/scripts/local-dev-down.sh" "$checkout_root/scripts/"
    cp "$REPO_ROOT/scripts/lib/process.sh" \
        "$REPO_ROOT/scripts/lib/env.sh" \
        "$REPO_ROOT/scripts/lib/db_url.sh" \
        "$REPO_ROOT/scripts/lib/compose_project.sh" \
        "$REPO_ROOT/scripts/lib/docker.sh" \
        "$REPO_ROOT/scripts/lib/local_source_providers.sh" \
        "$REPO_ROOT/scripts/lib/playwright_port_plan.sh" \
        "$checkout_root/scripts/lib/"
    cp "$REPO_ROOT/web/playwright.config.contract.ts" "$checkout_root/web/"
}

write_mock_script() {
    local path="$1" body="$2"
    cat > "$path" << MOCK
#!/usr/bin/env bash
$body
MOCK
    chmod +x "$path"
}

process_is_live_non_zombie() {
    local pid="$1"
    local state

    state="$(ps -p "$pid" -o stat= 2>/dev/null | awk '{print $1}')"
    [ -n "$state" ] && [[ "$state" != Z* ]] && [[ "$state" != *E* ]]
}

# ============================================================================
# Tests
# ============================================================================

test_kills_flapjack_via_pid_file() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local pid_dir="$LOCAL_DEV_TEST_REPO_ROOT/.local"
    mkdir -p "$pid_dir"

    # Spawn a fake service whose ps comm= shows "flapjack", registered for reaping.
    local fj_pid
    spawn_named_test_service "$tmp_dir" "flapjack"
    fj_pid="$FJCLOUD_TEST_LAST_SPAWNED_PID"
    echo "$fj_pid" > "$pid_dir/flapjack.pid"

    # Mock docker
    write_mock_script "$tmp_dir/docker" 'exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" run_local_dev_down 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "local-dev-down should succeed"

    if process_is_live_non_zombie "$fj_pid"; then
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
    output=$(PATH="$tmp_dir:$PATH" run_local_dev_down 2>&1) || exit_code=$?

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
    output=$(PATH="$tmp_dir:$PATH" run_local_dev_down --clean 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "local-dev-down --clean should succeed"

    local docker_args
    docker_args=$(cat "$tmp_dir/docker_calls.log" 2>/dev/null || true)
    assert_contains "$docker_args" "-v" \
        "--clean should add -v to docker compose down"
}

test_clean_flag_removes_default_flapjack_data_dirs() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local pid_dir="$LOCAL_DEV_TEST_REPO_ROOT/.local"
    mkdir -p \
        "$pid_dir/flapjack-data" \
        "$pid_dir/flapjack-data-us-east-1" \
        "$pid_dir/flapjack-data-eu-west-1" \
        "$pid_dir/flapjack-data-eu-central-1" \
        "$pid_dir/flapjack-data-playwright-17700"
    touch "$pid_dir/flapjack-data-us-east-1/stale-fixture"

    write_mock_script "$tmp_dir/docker" 'exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" run_local_dev_down --clean 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "local-dev-down --clean should succeed when removing Flapjack data dirs"

    if [ -e "$pid_dir/flapjack-data" ] \
        || [ -e "$pid_dir/flapjack-data-us-east-1" ] \
        || [ -e "$pid_dir/flapjack-data-eu-west-1" ] \
        || [ -e "$pid_dir/flapjack-data-eu-central-1" ]; then
        fail "--clean should remove default local-dev Flapjack data dirs"
    else
        pass "--clean removed default local-dev Flapjack data dirs"
    fi

    if [ -d "$pid_dir/flapjack-data-playwright-17700" ]; then
        pass "--clean preserves Playwright-scoped Flapjack data dirs"
    else
        fail "--clean should not remove Playwright-scoped Flapjack data dirs"
    fi
}

test_removes_log_files_and_pid_directory() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local pid_dir="$LOCAL_DEV_TEST_REPO_ROOT/.local"
    mkdir -p "$pid_dir"
    echo "test log" > "$pid_dir/flapjack.log"

    write_mock_script "$tmp_dir/docker" 'exit 0'

    PATH="$tmp_dir:$PATH" run_local_dev_down 2>&1 >/dev/null

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
    PATH="$tmp_dir:$PATH" run_local_dev_down 2>&1 >/dev/null || exit1=$?
    PATH="$tmp_dir:$PATH" run_local_dev_down 2>&1 >/dev/null || exit2=$?

    assert_eq "$exit1" "0" "first teardown should succeed (nothing running)"
    assert_eq "$exit2" "0" "second teardown should succeed (idempotent)"
}

test_removes_only_local_dev_generated_platform_test_cargo_env() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local config_path="$LOCAL_DEV_TEST_REPO_ROOT/infra/.cargo/config.toml"
    mkdir -p "$(dirname "$config_path")"
    printf '%s\n' \
        '# Generated by scripts/local-dev-up.sh for lane-local platform tests.' \
        '[env]' \
        'FJCLOUD_ALGOLIA_SOURCE_BASE_URL = "http://127.0.0.1:17800"' \
        > "$config_path"
    write_mock_script "$tmp_dir/docker" 'exit 0'

    PATH="$tmp_dir:$PATH" run_local_dev_down >/dev/null 2>&1

    if [ -e "$config_path" ]; then
        fail "local-dev-down should remove local-dev-up-generated Cargo source env when its runtime stops"
    else
        pass "local-dev-down removes local-dev-up-generated Cargo source env with the stopped runtime"
    fi

    mkdir -p "$(dirname "$config_path")"
    printf '%s\n' '[build]' 'target-dir = "custom-target"' > "$config_path"
    PATH="$tmp_dir:$PATH" run_local_dev_down >/dev/null 2>&1
    assert_eq "$(cat "$config_path")" $'[build]\ntarget-dir = "custom-target"' \
        "local-dev-down should preserve operator-owned Cargo configuration"
}

test_cleans_up_metering_agent_pid_files() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local pid_dir="$LOCAL_DEV_TEST_REPO_ROOT/.local"
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
    output=$(PATH="$tmp_dir:$PATH" run_local_dev_down 2>&1) || exit_code=$?

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

    local pid_dir="$LOCAL_DEV_TEST_REPO_ROOT/.local"
    mkdir -p "$pid_dir"

    # Create fake multi-region flapjack PID files (non-running PIDs).
    echo "99996" > "$pid_dir/flapjack-us-east-1.pid"
    echo "99995" > "$pid_dir/flapjack-eu-west-1.pid"
    echo "99994" > "$pid_dir/flapjack-eu-central-1.pid"

    write_mock_script "$tmp_dir/docker" 'exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" run_local_dev_down 2>&1) || exit_code=$?

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

    local pid_dir="$LOCAL_DEV_TEST_REPO_ROOT/.local"
    mkdir -p "$pid_dir"

    # Spawn a fake service whose ps comm= matches the expected_cmd, registered for reaping.
    local agent_pid
    spawn_named_test_service "$tmp_dir" "metering-agent"
    agent_pid="$FJCLOUD_TEST_LAST_SPAWNED_PID"
    echo "$agent_pid" > "$pid_dir/metering-agent-us-east-1.pid"

    write_mock_script "$tmp_dir/docker" 'exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" run_local_dev_down 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "local-dev-down should succeed"

    if process_is_live_non_zombie "$agent_pid"; then
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

    local pid_dir="$LOCAL_DEV_TEST_REPO_ROOT/.local"
    mkdir -p "$pid_dir"

    local api_pid web_pid
    spawn_named_test_service "$tmp_dir" "fjcloud-api"
    api_pid="$FJCLOUD_TEST_LAST_SPAWNED_PID"
    spawn_named_test_service "$tmp_dir" "npm"
    web_pid="$FJCLOUD_TEST_LAST_SPAWNED_PID"
    echo "$api_pid" > "$pid_dir/api.pid"
    echo "$web_pid" > "$pid_dir/web.pid"

    write_mock_script "$tmp_dir/docker" 'exit 0'

    local output exit_code=0
    output=$(PATH="$tmp_dir:$PATH" run_local_dev_down 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "local-dev-down should succeed for local demo PIDs"

    if process_is_live_non_zombie "$api_pid"; then
        kill "$api_pid" 2>/dev/null || true
        fail "local demo API process should have been killed"
    else
        pass "local demo API process was killed via PID file"
    fi

    if process_is_live_non_zombie "$web_pid"; then
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

test_honors_fjcloud_repo_root_override() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_runtime_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_runtime_state "$tmp_dir"

    local fixture_root fixture_pid_dir script_checkout_root checkout_pid_dir checkout_sentinel
    fixture_root="$(create_local_dev_fixture_repo_root "$tmp_dir")"
    fixture_pid_dir="$fixture_root/.local"
    script_checkout_root="$tmp_dir/script_checkout"
    create_local_dev_down_script_checkout "$script_checkout_root"
    checkout_pid_dir="$script_checkout_root/.local"
    checkout_sentinel="$checkout_pid_dir/stage3_checkout_$$_${RANDOM}.log"
    mkdir -p "$checkout_pid_dir" "$fixture_pid_dir"
    printf 'checkout sentinel\n' > "$checkout_sentinel"
    printf 'fixture log\n' > "$fixture_pid_dir/flapjack.log"
    mkdir -p "$fixture_pid_dir/flapjack-data-us-east-1"

    write_mock_script "$tmp_dir/docker" \
        'echo "COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-} $@" >> "'"$tmp_dir"'/docker_calls.log"; exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:$PATH" \
        FJCLOUD_REPO_ROOT="$fixture_root" \
        COMPOSE_PROJECT_NAME="fjcloud_stage3_down_$$" \
        bash "$script_checkout_root/scripts/local-dev-down.sh" --clean 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "local-dev-down honors FJCLOUD_REPO_ROOT override"
    if [ -e "$fixture_pid_dir/flapjack.log" ]; then
        fail "override root .local log files are removed"
    else
        pass "override root .local log files are removed"
    fi
    if [ -e "$fixture_pid_dir/flapjack-data-us-east-1" ]; then
        fail "override root --clean removes default Flapjack data dirs"
    else
        pass "override root --clean removes default Flapjack data dirs"
    fi
    assert_file_exists "$checkout_sentinel" \
        "checkout-root sentinel remains untouched when FJCLOUD_REPO_ROOT is supplied"
    assert_contains "$(cat "$tmp_dir/docker_calls.log" 2>/dev/null || true)" \
        "COMPOSE_PROJECT_NAME=fjcloud_stage3_down_$$ compose down -v" \
        "explicit COMPOSE_PROJECT_NAME is passed through to docker compose down"
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
    test_clean_flag_removes_default_flapjack_data_dirs
    test_removes_log_files_and_pid_directory
    test_idempotent_when_nothing_running
    test_removes_only_local_dev_generated_platform_test_cargo_env
    test_cleans_up_metering_agent_pid_files
    test_cleans_up_multi_region_flapjack_pid_files
    test_kills_running_metering_agent_via_pid_file
    test_kills_local_demo_api_and_web_pid_files
    test_honors_fjcloud_repo_root_override

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
