#!/usr/bin/env bash
# Red contract test for canary failure-path alert dispatch.
#
# No-false-positive mutation check (must fail after mutation):
# - Mutate Stage 4 canary control flow to skip send_critical_alert on signup failure.
# - Re-run: bash scripts/tests/canary_alert_on_failure_test.sh
# - Expected: this test fails because alert dispatch stub is not invoked.

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

test_signup_failure_dispatches_alert_with_non_empty_title() {
    if ! require_canary_script; then
        return
    fi

    local tmp_dir curl_calls alert_calls alert_title
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    mkdir -p "$tmp_dir/bin"
    : > "$tmp_dir/curl_calls.log"
    : > "$tmp_dir/alert_calls.log"

    write_mock_script "$tmp_dir/bin/curl" 'set -euo pipefail
: "${CURL_CALL_LOG:?CURL_CALL_LOG is required}"
printf "%s\n" "$*" >> "$CURL_CALL_LOG"
exit "${MOCK_CURL_EXIT_CODE:-74}"'

    write_alert_dispatch_override "$tmp_dir/alert_dispatch_override.sh"

    run_canary "$tmp_dir" \
        "CANARY_QUIET_UNTIL_OVERRIDE=1" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "ALERT_DISPATCH_HELPER=$tmp_dir/alert_dispatch_override.sh" \
        "ALERT_DISPATCH_CALL_LOG=$tmp_dir/alert_calls.log" \
        "SLACK_WEBHOOK_URL=https://mock.slack.local/slack"

    if [ "$RUN_EXIT_CODE" -ne 0 ]; then
        pass "canary exits non-zero when signup HTTP step fails"
    else
        fail "canary exits non-zero when signup HTTP step fails"
    fi

    curl_calls="$(cat "$tmp_dir/curl_calls.log" 2>/dev/null || true)"
    alert_calls="$(cat "$tmp_dir/alert_calls.log" 2>/dev/null || true)"
    alert_title="$(sed -n 's/^title=//p' "$tmp_dir/alert_calls.log" | head -n 1)"

    assert_contains "$curl_calls" "/auth/register" \
        "failure path exercised signup request before alerting"
    assert_contains "$alert_calls" "signup" \
        "alert payload captures failed step name 'signup'"
    if [ -n "$alert_title" ]; then
        pass "alert dispatch receives a non-empty title argument"
    else
        fail "alert dispatch receives a non-empty title argument"
    fi
}

main() {
    echo "=== canary_alert_on_failure_test.sh ==="
    echo ""

    test_signup_failure_dispatches_alert_with_non_empty_title

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
