#!/usr/bin/env bash
# Red contract test for canary quiet-window short-circuit behavior.
#
# No-false-positive mutation check (must fail after mutation):
# - Mutate Stage 4 canary control flow to invert the quiet-window comparison.
# - Re-run: bash scripts/tests/canary_quiet_period_test.sh
# - Expected: this test fails because curl or alert stubs are invoked.

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

write_alert_dispatch_override() {
    local override_path="$1"
    cat > "$override_path" <<'OVERRIDE'
send_critical_alert() {
    : "${ALERT_DISPATCH_CALL_LOG:?ALERT_DISPATCH_CALL_LOG is required}"

    local channel="${1:-}"
    local webhook_url="${2:-}"
    local title="${3:-}"
    local message="${4:-}"
    local source="${5:-}"
    local nonce="${6:-}"
    local environment="${7:-}"

    {
        printf 'channel=%s\n' "$channel"
        printf 'webhook_url=%s\n' "$webhook_url"
        printf 'title=%s\n' "$title"
        printf 'message=%s\n' "$message"
        printf 'source=%s\n' "$source"
        printf 'nonce=%s\n' "$nonce"
        printf 'environment=%s\n' "$environment"
    } >> "$ALERT_DISPATCH_CALL_LOG"
}
OVERRIDE
}

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

test_quiet_window_short_circuits_without_http_or_alerts() {
    if ! require_canary_script; then
        return
    fi

    local tmp_dir quiet_until combined_output curl_calls alert_calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    mkdir -p "$tmp_dir/bin"
    : > "$tmp_dir/curl_calls.log"
    : > "$tmp_dir/alert_calls.log"

    write_mock_script "$tmp_dir/bin/curl" 'set -euo pipefail
: "${CURL_CALL_LOG:?CURL_CALL_LOG is required}"
printf "%s\n" "$*" >> "$CURL_CALL_LOG"
exit "${MOCK_CURL_EXIT_CODE:-71}"'

    write_alert_dispatch_override "$tmp_dir/alert_dispatch_override.sh"

    quiet_until="$(( $(date +%s) + 600 ))"

    run_canary "$tmp_dir" \
        "CANARY_QUIET_UNTIL_OVERRIDE=$quiet_until" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "ALERT_DISPATCH_HELPER=$tmp_dir/alert_dispatch_override.sh" \
        "ALERT_DISPATCH_CALL_LOG=$tmp_dir/alert_calls.log"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "canary exits 0 when CANARY_QUIET_UNTIL_OVERRIDE is in the future"

    combined_output="${RUN_STDOUT}"$'\n'"${RUN_STDERR}"
    assert_contains "$combined_output" "quiet window" \
        "canary logs explicit quiet-window branch evidence"

    curl_calls="$(cat "$tmp_dir/curl_calls.log" 2>/dev/null || true)"
    alert_calls="$(cat "$tmp_dir/alert_calls.log" 2>/dev/null || true)"

    assert_eq "$curl_calls" "" \
        "quiet-window branch does not invoke curl"
    assert_eq "$alert_calls" "" \
        "quiet-window branch does not invoke alert dispatch"
}

main() {
    echo "=== canary_quiet_period_test.sh ==="
    echo ""

    test_quiet_window_short_circuits_without_http_or_alerts

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
