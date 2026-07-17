#!/usr/bin/env bash
# Red contract test for expired quiet-window canary control flow.
#
# No-false-positive mutation check (must fail after mutation):
# - Mutate Stage 4 canary control flow to always exit from quiet-window logic.
# - Re-run: bash scripts/tests/canary_quiet_period_expired_test.sh
# - Expected: this test fails because no /auth/register request is attempted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANARY_SCRIPT="$REPO_ROOT/scripts/canary/customer_loop_synthetic.sh"

PASS_COUNT=0
FAIL_COUNT=0

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0

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
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

run_canary() {
    local tmp_dir="$1"
    shift

    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        ENVIRONMENT="staging" \
        "$@" \
        bash "$CANARY_SCRIPT" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

require_canary_script() {
    if [ -f "$CANARY_SCRIPT" ]; then
        pass "canary script exists at scripts/canary/customer_loop_synthetic.sh"
    else
        fail "canary script exists at scripts/canary/customer_loop_synthetic.sh"
        return 1
    fi

    if [ -x "$CANARY_SCRIPT" ]; then
        pass "canary script is executable"
    else
        fail "canary script is executable"
        return 1
    fi
}

test_expired_quiet_window_attempts_first_signup_step() {
    if ! require_canary_script; then
        return
    fi

    local tmp_dir curl_calls call_count
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    mkdir -p "$tmp_dir/bin"
    : > "$tmp_dir/curl_calls.log"
    printf '0' > "$tmp_dir/curl_count.log"

    write_mock_script "$tmp_dir/bin/curl" 'set -euo pipefail
: "${CURL_CALL_LOG:?CURL_CALL_LOG is required}"
: "${CURL_CALL_COUNT_FILE:?CURL_CALL_COUNT_FILE is required}"
count="$(cat "$CURL_CALL_COUNT_FILE" 2>/dev/null || printf "0")"
count=$((count + 1))
printf "%s" "$count" > "$CURL_CALL_COUNT_FILE"
printf "%s\n" "$*" >> "$CURL_CALL_LOG"
if [ "$count" -eq 1 ]; then
    exit "${MOCK_CURL_EXIT_CODE:-73}"
fi
exit 0'

    run_canary "$tmp_dir" \
        "CANARY_QUIET_UNTIL_OVERRIDE=1" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "CURL_CALL_COUNT_FILE=$tmp_dir/curl_count.log"

    if [ "$RUN_EXIT_CODE" -ne 0 ]; then
        pass "expired quiet-window path exits non-zero after first failing HTTP attempt"
    else
        fail "expired quiet-window path exits non-zero after first failing HTTP attempt"
    fi

    curl_calls="$(cat "$tmp_dir/curl_calls.log" 2>/dev/null || true)"
    call_count="$(cat "$tmp_dir/curl_count.log" 2>/dev/null || true)"

    assert_contains "$curl_calls" "/auth/register" \
        "expired quiet-window path attempts signup request (/auth/register)"
    assert_contains "$call_count" "1" \
        "curl stub observed at least one attempted request"
}

main() {
    echo "=== canary_quiet_period_expired_test.sh ==="
    echo ""

    test_expired_quiet_window_attempts_first_signup_step

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
