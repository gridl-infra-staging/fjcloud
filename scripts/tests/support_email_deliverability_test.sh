#!/usr/bin/env bash
# Tests for scripts/canary/support_email_deliverability.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"
source "$REPO_ROOT/scripts/tests/lib/test_helpers.sh"

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

support_email_roundtrip_mock_body() {
    cat <<'MOCK'
set -euo pipefail
echo "$*" >> "${SUPPORT_EMAIL_TEST_ROUNDTRIP_CALL_LOG:?missing roundtrip call log}"
printf '%s\n' "${SUPPORT_EMAIL_TEST_ROUNDTRIP_OUTPUT:?missing roundtrip output}"
exit "${SUPPORT_EMAIL_TEST_ROUNDTRIP_EXIT_CODE:-0}"
MOCK
}

write_mock_alert_dispatch_lib() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

alert_dispatch_send_critical() {
    local slack_url="$1"
    local discord_url="$2"
    local title="$3"
    local message="$4"
    local source="$5"
    local nonce="$6"
    local environment="$7"

    printf 'CALL|slack=%s|discord=%s|title=%s|message=%s|source=%s|nonce=%s|env=%s\n' \
        "$slack_url" "$discord_url" "$title" "$message" "$source" "$nonce" "$environment" \
        >> "${SUPPORT_EMAIL_TEST_ALERT_LOG:?missing alert log path}"
    return "${SUPPORT_EMAIL_TEST_ALERT_EXIT_CODE:-0}"
}
MOCK
}

new_support_email_mock_workspace() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    write_mock_script "$mock_dir/mock_roundtrip.sh" "$(support_email_roundtrip_mock_body)"
    write_mock_alert_dispatch_lib "$mock_dir/mock_alert_dispatch.sh"
    : > "$mock_dir/roundtrip_calls.log"
    : > "$mock_dir/alert_calls.log"
    echo "$mock_dir"
}

run_support_email_canary() {
    local mock_dir="$1"
    shift
    env -i \
        "PATH=/usr/bin:/bin" \
        "SUPPORT_EMAIL_ROUNDTRIP_SCRIPT=$mock_dir/mock_roundtrip.sh" \
        "SUPPORT_EMAIL_ALERT_LIB=$mock_dir/mock_alert_dispatch.sh" \
        "SUPPORT_EMAIL_TEST_ROUNDTRIP_CALL_LOG=$mock_dir/roundtrip_calls.log" \
        "SUPPORT_EMAIL_TEST_ALERT_LOG=$mock_dir/alert_calls.log" \
        "$@" \
        bash "$REPO_ROOT/scripts/canary/support_email_deliverability.sh" 2>&1
}

assert_single_alert_with_classification() {
    local alert_log="$1"
    local expected_classification="$2"
    local expected_detail="$3"
    local alert_count alert_line

    alert_count="$(wc -l < "$alert_log" | tr -d '[:space:]')"
    alert_line="$(cat "$alert_log")"

    assert_eq "$alert_count" "1" "failure path should dispatch exactly one critical alert"
    assert_contains "$alert_line" "source=support_email_deliverability.sh" "alert payload should preserve support_email_deliverability source name"
    assert_contains "$alert_line" "classification=${expected_classification}" "alert payload should include delegated failure classification"
    assert_contains "$alert_line" "$expected_detail" "alert payload should include delegated failure detail"
}

test_canary_delegates_to_roundtrip_owner_on_success_without_alert_dispatch() {
    local mock_dir output exit_code roundtrip_count alert_count
    mock_dir="$(new_support_email_mock_workspace)"

    output="$(
        run_support_email_canary "$mock_dir" \
            "SUPPORT_EMAIL_TEST_ROUNDTRIP_EXIT_CODE=0" \
            "SUPPORT_EMAIL_TEST_ROUNDTRIP_OUTPUT={\"passed\":true,\"steps\":[{\"name\":\"send_probe\",\"passed\":true,\"detail\":\"ok\"}]}" \
            "SLACK_WEBHOOK_URL=https://hooks.slack.test/services/canary"
    )" || exit_code=$?

    roundtrip_count="$(wc -l < "$mock_dir/roundtrip_calls.log" | tr -d '[:space:]')"
    alert_count="$(wc -l < "$mock_dir/alert_calls.log" | tr -d '[:space:]')"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "canary should return success when delegated roundtrip succeeds"
    assert_eq "$roundtrip_count" "1" "canary should execute delegated roundtrip exactly once on success"
    assert_eq "$alert_count" "0" "canary should not dispatch alerts on delegated success"
    assert_contains "$output" "\"passed\":true" "canary should forward delegated roundtrip output on success"
}

test_canary_dispatches_one_critical_alert_on_timeout_failure() {
    local mock_dir output exit_code
    mock_dir="$(new_support_email_mock_workspace)"

    output="$(
        run_support_email_canary "$mock_dir" \
            "SUPPORT_EMAIL_TEST_ROUNDTRIP_EXIT_CODE=21" \
            "SUPPORT_EMAIL_TEST_ROUNDTRIP_OUTPUT={\"passed\":false,\"steps\":[{\"name\":\"poll_inbox_s3\",\"passed\":false,\"detail\":\"Timed out waiting for nonce stage2-timeout\"}]}" \
            "SLACK_WEBHOOK_URL=https://hooks.slack.test/services/canary" \
            "ENVIRONMENT=staging"
    )" || exit_code=$?

    assert_eq "${exit_code:-0}" "21" "canary should preserve delegated timeout exit code"
    assert_contains "$output" "\"passed\":false" "timeout path should still emit delegated roundtrip output for diagnostics"
    assert_single_alert_with_classification "$mock_dir/alert_calls.log" "timeout" "Timed out waiting for nonce stage2-timeout"
    rm -rf "$mock_dir"
}

test_canary_dispatches_one_critical_alert_on_auth_failure() {
    local mock_dir output exit_code
    mock_dir="$(new_support_email_mock_workspace)"

    output="$(
        run_support_email_canary "$mock_dir" \
            "SUPPORT_EMAIL_TEST_ROUNDTRIP_EXIT_CODE=22" \
            "SUPPORT_EMAIL_TEST_ROUNDTRIP_OUTPUT={\"passed\":false,\"steps\":[{\"name\":\"auth_verdict\",\"passed\":false,\"detail\":\"Authentication-Results failed. failed_components=dkim\"}]}" \
            "DISCORD_WEBHOOK_URL=https://discord.test/api/webhooks/canary" \
            "ENVIRONMENT=prod"
    )" || exit_code=$?

    assert_eq "${exit_code:-0}" "22" "canary should preserve delegated auth-failure exit code"
    assert_contains "$output" "\"passed\":false" "auth-failure path should still emit delegated roundtrip output for diagnostics"
    assert_single_alert_with_classification "$mock_dir/alert_calls.log" "auth_failure" "failed_components=dkim"
    rm -rf "$mock_dir"
}

test_canary_dispatches_one_critical_alert_on_runtime_failure() {
    local mock_dir output exit_code
    mock_dir="$(new_support_email_mock_workspace)"

    output="$(
        run_support_email_canary "$mock_dir" \
            "SUPPORT_EMAIL_TEST_ROUNDTRIP_EXIT_CODE=1" \
            "SUPPORT_EMAIL_TEST_ROUNDTRIP_OUTPUT={\"passed\":false,\"steps\":[{\"name\":\"send_probe\",\"passed\":false,\"detail\":\"aws sesv2 send-email failed\"}]}" \
            "SLACK_WEBHOOK_URL=https://hooks.slack.test/services/canary" \
            "DISCORD_WEBHOOK_URL=https://discord.test/api/webhooks/canary" \
            "ENVIRONMENT=dev"
    )" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "canary should preserve delegated runtime-failure exit code"
    assert_contains "$output" "\"passed\":false" "runtime-failure path should still emit delegated roundtrip output for diagnostics"
    assert_single_alert_with_classification "$mock_dir/alert_calls.log" "runtime" "aws sesv2 send-email failed"
    rm -rf "$mock_dir"
}

echo "=== support_email_deliverability.sh tests ==="
test_canary_delegates_to_roundtrip_owner_on_success_without_alert_dispatch
test_canary_dispatches_one_critical_alert_on_timeout_failure
test_canary_dispatches_one_critical_alert_on_auth_failure
test_canary_dispatches_one_critical_alert_on_runtime_failure

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
