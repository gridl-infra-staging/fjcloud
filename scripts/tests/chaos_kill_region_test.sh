#!/usr/bin/env bash
# Focused tests for scripts/chaos/kill-region.sh.
# Uses mock binaries and temp directories; does not touch real services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/local_dev_test_state.sh
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"
# shellcheck source=lib/chaos_test_helpers.sh
source "$SCRIPT_DIR/lib/chaos_test_helpers.sh"

test_kill_region_kills_process_via_pid_file() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_kill_region_test_root "$tmp_dir"

    # Create a PID dir and a fake process to kill.
    local pid_dir="$tmp_dir/.local"

    # Start a background sleep as our "flapjack" process.
    sleep 60 &
    local fake_pid=$!
    echo "$fake_pid" > "$pid_dir/flapjack-eu-west-1.pid"

    # Run kill-region.sh with PID_DIR overridden via a wrapper that
    # sets REPO_ROOT to our temp dir.
    local output exit_code=0
    output=$(bash "$tmp_dir/scripts/chaos/kill-region.sh" "eu-west-1" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "kill-region should succeed when PID file exists"
    assert_contains "$output" "Killed flapjack-eu-west-1" \
        "should report the killed region"

    # Verify the process was actually killed.
    if kill -0 "$fake_pid" 2>/dev/null; then
        fail "process should have been killed"
        kill "$fake_pid" 2>/dev/null || true
    else
        pass "process was killed via PID file"
    fi

    # Verify PID file was removed.
    if [ ! -f "$pid_dir/flapjack-eu-west-1.pid" ]; then
        pass "PID file was removed after kill"
    else
        fail "PID file should have been removed"
    fi
}


test_kill_region_fails_without_pid_file() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    # No PID file — kill-region should fail.
    setup_kill_region_test_root "$tmp_dir"

    local output exit_code=0
    output=$(bash "$tmp_dir/scripts/chaos/kill-region.sh" "us-east-1" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "kill-region should fail when no PID file exists"
    assert_contains "$output" "No PID file" \
        "should report that no PID file was found"
}


test_kill_region_handles_dead_process() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_kill_region_test_root "$tmp_dir"
    local pid_dir="$tmp_dir/.local"

    # Write a PID for a process that doesn't exist (99999999).
    echo "99999999" > "$pid_dir/flapjack-eu-central-1.pid"

    local output exit_code=0
    output=$(bash "$tmp_dir/scripts/chaos/kill-region.sh" "eu-central-1" 2>&1) || exit_code=$?

    # Script should succeed but report the process as already dead.
    assert_eq "$exit_code" "0" "kill-region should succeed even if process is already dead"
    assert_contains "$output" "not running" \
        "should report that the process is already dead"
}


test_kill_region_requires_region_argument() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_kill_region_test_root "$tmp_dir"

    local output exit_code=0
    output=$(bash "$tmp_dir/scripts/chaos/kill-region.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "kill-region should fail without region argument"
}

# ============================================================================
# restart-region.sh tests
# ============================================================================


test_kill_region_uses_config_aware_timing_message() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_kill_region_test_root "$tmp_dir"
    local pid_dir="$tmp_dir/.local"

    sleep 60 &
    local fake_pid=$!
    echo "$fake_pid" > "$pid_dir/flapjack-eu-west-1.pid"

    local output exit_code=0
    output=$(
        REGION_FAILOVER_CYCLE_INTERVAL_SECS=10 \
        REGION_FAILOVER_UNHEALTHY_THRESHOLD=5 \
        bash "$tmp_dir/scripts/chaos/kill-region.sh" "eu-west-1" 2>&1
    ) || exit_code=$?

    # Kill leftover process if script didn't.
    kill "$fake_pid" 2>/dev/null || true

    assert_eq "$exit_code" "0" "kill-region config-aware messaging should succeed"
    assert_contains "$output" "50s" \
        "kill-region should display computed timing (10*5=50s)"
    assert_not_contains "$output" "180s" \
        "kill-region should NOT contain old hardcoded 180s"
    assert_contains "$output" "10s interval" \
        "kill-region should display the configured interval"
}

# ============================================================================
# restart-region.sh messaging-contract tests
# ============================================================================


main() {
    echo "=== chaos kill-region tests ==="
    echo ""

    test_kill_region_kills_process_via_pid_file
    test_kill_region_fails_without_pid_file
    test_kill_region_handles_dead_process
    test_kill_region_requires_region_argument
    test_kill_region_uses_config_aware_timing_message

    run_test_summary
}

main "$@"
