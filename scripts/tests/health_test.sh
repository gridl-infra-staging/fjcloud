#!/usr/bin/env bash
# Tests for scripts/lib/health.sh: wait_for_health and check_port_available.
# Uses mock curl/lsof — does NOT touch real services.

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

# Caller-provided log() required by health.sh
LOG_OUTPUT=""
log() { LOG_OUTPUT+="[health-test] $*"$'\n'; }

# shellcheck source=../../scripts/lib/health.sh
source "$REPO_ROOT/scripts/lib/health.sh"

# ============================================================================
# wait_for_health tests
# ============================================================================

test_wait_for_health_returns_zero_on_immediate_success() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Mock curl that always succeeds
    cat > "$tmp_dir/curl" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$tmp_dir/curl"

    LOG_OUTPUT=""
    local exit_code=0
    PATH="$tmp_dir:$PATH" wait_for_health "http://localhost:9999/health" "test-svc" 1 || exit_code=$?

    assert_eq "$exit_code" "0" "wait_for_health should return 0 when curl succeeds"
    assert_contains "$LOG_OUTPUT" "test-svc is healthy" \
        "log should report service healthy"
}

test_wait_for_health_returns_nonzero_on_timeout() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Mock curl that always fails
    cat > "$tmp_dir/curl" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$tmp_dir/curl"

    # Override sleep to be instant for fast test
    cat > "$tmp_dir/sleep" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$tmp_dir/sleep"

    LOG_OUTPUT=""
    local exit_code=0
    PATH="$tmp_dir:$PATH" wait_for_health "http://localhost:9999/health" "test-svc" 1 || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "wait_for_health returns non-zero on timeout"
    else
        fail "wait_for_health should return non-zero when curl never succeeds"
    fi

    assert_contains "$LOG_OUTPUT" "failed health check" \
        "log should report health check failure"
}

test_wait_for_health_respects_max_wait() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Mock curl that always fails, and sleep that logs calls
    cat > "$tmp_dir/curl" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$tmp_dir/curl"

    cat > "$tmp_dir/sleep" << MOCK
#!/usr/bin/env bash
echo "\$1" >> "$tmp_dir/sleep_calls.log"
exit 0
MOCK
    chmod +x "$tmp_dir/sleep"

    LOG_OUTPUT=""
    PATH="$tmp_dir:$PATH" wait_for_health "http://localhost:9999/health" "test-svc" 3 || true

    local sleep_count
    sleep_count=$(wc -l < "$tmp_dir/sleep_calls.log" | tr -d ' ')
    assert_eq "$sleep_count" "3" "wait_for_health should sleep exactly max_wait times"
}

# ============================================================================
# check_port_available tests
# ============================================================================

test_check_port_available_returns_zero_when_free() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Mock lsof that reports nothing listening
    cat > "$tmp_dir/lsof" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$tmp_dir/lsof"

    LOG_OUTPUT=""
    local exit_code=0
    PATH="$tmp_dir:$PATH" check_port_available 7700 "flapjack" || exit_code=$?

    assert_eq "$exit_code" "0" "check_port_available should return 0 when port is free"
}

test_check_port_available_returns_nonzero_when_occupied() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Mock lsof that reports a listener
    cat > "$tmp_dir/lsof" << 'MOCK'
#!/usr/bin/env bash
echo "COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME"
echo "node    12345 user   22u  IPv4 0x1234      0t0  TCP *:7700 (LISTEN)"
exit 0
MOCK
    chmod +x "$tmp_dir/lsof"

    LOG_OUTPUT=""
    local exit_code=0
    PATH="$tmp_dir:$PATH" check_port_available 7700 "flapjack" || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "check_port_available returns non-zero when port is occupied"
    else
        fail "check_port_available should return non-zero when port is in use"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== health.sh tests ==="
    echo ""

    echo "--- wait_for_health ---"
    test_wait_for_health_returns_zero_on_immediate_success
    test_wait_for_health_returns_nonzero_on_timeout
    test_wait_for_health_respects_max_wait

    echo ""
    echo "--- check_port_available ---"
    test_check_port_available_returns_zero_when_free
    test_check_port_available_returns_nonzero_when_occupied

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
