#!/usr/bin/env bash
# Tests for scripts/lib/process.sh: kill_pid_file function.
# Uses real sleep processes and temp PID files — does NOT touch real services.

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

# Caller-provided log() required by process.sh
LOG_OUTPUT=""
log() { LOG_OUTPUT+="[process-test] $*"$'\n'; }

# shellcheck source=../../scripts/lib/process.sh
source "$REPO_ROOT/scripts/lib/process.sh"

# ============================================================================
# Tests
# ============================================================================

test_kills_running_process_with_matching_command() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Start a background sleep process
    sleep 300 &
    local pid=$!
    echo "$pid" > "$tmp_dir/test.pid"

    LOG_OUTPUT=""
    kill_pid_file "$tmp_dir/test.pid" "test-process" "sleep"

    # Process should be dead
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        fail "kill_pid_file should have killed the process"
    else
        pass "kill_pid_file kills running process with matching command"
    fi

    assert_contains "$LOG_OUTPUT" "Stopping test-process" \
        "log should mention stopping the named process"
}

test_skips_kill_when_command_does_not_match() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Start a background sleep process
    sleep 300 &
    local pid=$!
    echo "$pid" > "$tmp_dir/test.pid"

    LOG_OUTPUT=""
    kill_pid_file "$tmp_dir/test.pid" "flapjack" "flapjack"

    # Process should still be alive (command is "sleep", not "flapjack")
    if kill -0 "$pid" 2>/dev/null; then
        pass "kill_pid_file skips kill when command name does not match"
        kill "$pid" 2>/dev/null || true
    else
        fail "kill_pid_file should NOT have killed process with mismatched command name"
    fi

    assert_contains "$LOG_OUTPUT" "stale PID file" \
        "log should mention stale PID file when command doesn't match"
}

test_removes_pid_file_regardless_of_process_state() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Case 1: PID file with a process that no longer exists
    echo "99999" > "$tmp_dir/stale.pid"

    LOG_OUTPUT=""
    kill_pid_file "$tmp_dir/stale.pid" "stale-process" "something"

    if [ -f "$tmp_dir/stale.pid" ]; then
        fail "kill_pid_file should remove PID file even when process is not running"
    else
        pass "kill_pid_file removes PID file for non-running process"
    fi

    # Case 2: PID file with a running process that gets killed
    sleep 300 &
    local pid=$!
    echo "$pid" > "$tmp_dir/running.pid"

    LOG_OUTPUT=""
    kill_pid_file "$tmp_dir/running.pid" "running-process" "sleep"

    if [ -f "$tmp_dir/running.pid" ]; then
        fail "kill_pid_file should remove PID file after killing process"
    else
        pass "kill_pid_file removes PID file after killing process"
    fi
}

test_returns_cleanly_when_no_pid_file() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    LOG_OUTPUT=""
    local exit_code=0
    kill_pid_file "$tmp_dir/nonexistent.pid" "ghost-process" "ghost" || exit_code=$?

    assert_eq "$exit_code" "0" "kill_pid_file should return 0 when PID file does not exist"
    assert_contains "$LOG_OUTPUT" "no PID file found" \
        "log should report no PID file found"
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== process.sh tests ==="
    echo ""

    test_kills_running_process_with_matching_command
    test_skips_kill_when_command_does_not_match
    test_removes_pid_file_regardless_of_process_state
    test_returns_cleanly_when_no_pid_file

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
