#!/usr/bin/env bash
# Regression test for the customer-loop canary's AWS/inbox probe-env gap
# classification. Prereq gaps must SKIP with the canonical shared token before
# customer-path HTTP, S3 polling, cleanup, or alert side effects can start.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANARY_SCRIPT="$REPO_ROOT/scripts/canary/customer_loop_synthetic.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/test_helpers.sh"

if [ ! -f "$CANARY_SCRIPT" ]; then
    fail "canary script exists at scripts/canary/customer_loop_synthetic.sh"
    run_test_summary
    exit 1
fi

run_canary_case() {
    local aws_mode="$1"
    local quiet_window_mode="$2"
    local inbox_s3_uri="$3"
    local inbox_domain="$4"
    local caller_inbox_s3_uri="${5:-__unset__}"
    local caller_inbox_domain="${6:-__unset__}"
    local tmp_dir mock_dir env_file aws_log curl_log alert_log stdout_file stderr_file
    local alert_override quiet_until
    local env_args=()

    tmp_dir="$(mktemp -d -t customer_loop_probe_env_gap_XXXXXX)"
    mock_dir="$tmp_dir/bin"
    env_file="$tmp_dir/canary.env"
    aws_log="$tmp_dir/aws.calls"
    curl_log="$tmp_dir/curl.calls"
    alert_log="$tmp_dir/alert.calls"
    stdout_file="$tmp_dir/stdout.log"
    stderr_file="$tmp_dir/stderr.log"
    alert_override="$REPO_ROOT/scripts/lib/customer_loop_probe_env_gap_alert_override_$$.sh"
    case "$quiet_window_mode" in
        active)
            quiet_until="$(($(date +%s) + 600))"
            ;;
        expired)
            quiet_until="1"
            ;;
        *)
            fail "unexpected quiet_window_mode=${quiet_window_mode}"
            run_test_summary
            exit 1
            ;;
    esac
    mkdir -p "$mock_dir"
    : > "$aws_log"
    : > "$curl_log"
    : > "$alert_log"

    {
        printf 'ENVIRONMENT=staging\n'
        printf 'API_URL=https://api.staging.flapjack.foo\n'
        printf 'ADMIN_KEY=local-admin-key-123456\n'
        printf 'STRIPE_SECRET_KEY=sk_test_customer_loop_probe_env_gap\n'
        printf 'CANARY_AWS_REGION=us-east-1\n'
        printf 'CANARY_LIVE_MODE=0\n'
        printf 'SLACK_WEBHOOK_URL=https://mock.slack.local/customer-loop-probe-env-gap\n'
        if [ "$inbox_s3_uri" != "__omit__" ]; then
            printf 'CANARY_TEST_INBOX_S3_URI=%s\n' "$inbox_s3_uri"
        fi
        if [ "$inbox_domain" != "__omit__" ]; then
            printf 'CANARY_TEST_INBOX_DOMAIN=%s\n' "$inbox_domain"
        fi
    } > "$env_file"

    if [ "$aws_mode" != "missing_cli" ]; then
        write_mock_script "$mock_dir/aws" "$(cat <<'EOF_AWS'
set -euo pipefail
printf '%s\n' "$*" >> "${AWS_CALLS_LOG:?missing AWS_CALLS_LOG}"
printf 'env_s3=%s\n' "${CANARY_TEST_INBOX_S3_URI:-}" >> "$AWS_CALLS_LOG"
printf 'env_domain=%s\n' "${CANARY_TEST_INBOX_DOMAIN:-}" >> "$AWS_CALLS_LOG"

if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
    if [[ "${MOCK_AWS_STS_MODE:-ok}" == "ok" ]]; then
        printf '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/probe-env-gap","UserId":"AIDAPROBE"}\n'
        exit 0
    fi
    echo "InvalidClientTokenId" >&2
    exit 255
fi

echo "unexpected aws invocation: $*" >&2
exit 99
EOF_AWS
)"
    fi
    write_mock_script "$mock_dir/curl" "$(cat <<'EOF_CURL'
set -euo pipefail
: "${CURL_CALL_LOG:?missing CURL_CALL_LOG}"
printf '%s\n' "$*" >> "$CURL_CALL_LOG"
for arg in "$@"; do
    if [[ "$arg" == *canary+*@* ]]; then
        printf 'payload=%s\n' "$arg" >> "$CURL_CALL_LOG"
    fi
done
printf 'mock curl forced failure\n'
exit 71
EOF_CURL
)"
    cat > "$alert_override" <<'EOF_ALERT'
send_critical_alert() {
    : "${ALERT_DISPATCH_CALL_LOG:?ALERT_DISPATCH_CALL_LOG is required}"
    printf 'channel=%s title=%s message=%s\n' "${1:-}" "${3:-}" "${4:-}" >> "$ALERT_DISPATCH_CALL_LOG"
}
EOF_ALERT

    RUN_EXIT_CODE=0
    env_args=(
        "HOME=$tmp_dir"
        "PATH=$mock_dir:/usr/bin:/bin:/usr/sbin:/sbin"
        "FJCLOUD_SECRET_FILE=$env_file"
        "CANARY_QUIET_UNTIL_OVERRIDE=$quiet_until"
        "MOCK_AWS_STS_MODE=$aws_mode"
        "AWS_CALLS_LOG=$aws_log"
        "CURL_CALL_LOG=$curl_log"
        "ALERT_DISPATCH_HELPER=$alert_override"
        "ALERT_DISPATCH_CALL_LOG=$alert_log"
    )
    if [ "$caller_inbox_s3_uri" != "__unset__" ]; then
        env_args+=("CANARY_TEST_INBOX_S3_URI=$caller_inbox_s3_uri")
    fi
    if [ "$caller_inbox_domain" != "__unset__" ]; then
        env_args+=("CANARY_TEST_INBOX_DOMAIN=$caller_inbox_domain")
    fi

    env -i "${env_args[@]}" bash "$CANARY_SCRIPT" --probe-only >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    RUN_AWS_CALLS="$(cat "$aws_log" 2>/dev/null || true)"
    RUN_CURL_CALLS="$(cat "$curl_log" 2>/dev/null || true)"
    RUN_ALERT_CALLS="$(cat "$alert_log" 2>/dev/null || true)"

    rm -f "$alert_override"
    rm -rf "$tmp_dir"
}

assert_prereq_skip_case() {
    local token="$1"
    local detail="$2"
    local expected_aws_call_count="$3"
    local json_line aws_call_count combined_output

    assert_eq "$RUN_EXIT_CODE" "100" "$token should return the skip exit code"
    combined_output="${RUN_STDOUT}"$'\n'"${RUN_STDERR}"
    assert_contains "$combined_output" "SKIPPED: $token: $detail" \
        "$token should print the canonical skip line and shared detail"

    json_line="$(final_stdout_json_line "$RUN_STDOUT")"
    assert_valid_json "$json_line" "$token should emit one final JSON line"
    assert_contains "$json_line" '"status": "skip"' "skip JSON should report status=skip"
    assert_contains "$json_line" '"exit_code": 100' "skip JSON should report exit_code=100"
    assert_contains "$json_line" "\"skip_reason\": \"$token\"" \
        "skip JSON should use the canonical $token token"
    assert_contains "$json_line" "$detail" "skip JSON should preserve the shared detail for $token"

    aws_call_count="$(printf '%s\n' "$RUN_AWS_CALLS" | grep -Ec '^sts get-caller-identity$' || true)"
    assert_eq "$aws_call_count" "$expected_aws_call_count" \
        "$token should perform the expected number of aws preflight calls"
    assert_not_contains "$RUN_AWS_CALLS" "s3api" "$token should skip before inbox polling S3 runtime work"
    assert_eq "$RUN_CURL_CALLS" "" "$token should skip before signup or cleanup HTTP work"
    assert_eq "$RUN_ALERT_CALLS" "" "$token should skip before alert dispatch starts"
}

test_missing_aws_cli_returns_skip_json_without_side_effects() {
    run_canary_case "missing_cli" "expired" \
        "s3://flapjack-cloud-releases/e2e-emails/" "test.flapjack.foo"

    assert_prereq_skip_case \
        "probe_env_gap_aws_credentials_unavailable" \
        "aws CLI unavailable" \
        "0"
}

test_invalid_aws_credentials_returns_skip_json_without_customer_side_effects() {
    run_canary_case "invalid" "expired" \
        "s3://flapjack-cloud-releases/e2e-emails/" "test.flapjack.foo"

    assert_prereq_skip_case \
        "probe_env_gap_aws_credentials_invalid" \
        "aws sts get-caller-identity failed; creds present but rejected by AWS" \
        "1"
    assert_contains "$RUN_AWS_CALLS" "sts get-caller-identity" \
        "invalid credentials should be classified by the shared sts preflight"
}

assert_successful_prereq_auth_reaches_signup() {
    local expected_domain="$1"
    local expected_s3_uri="$2"
    local aws_call_count

    assert_ne "$RUN_EXIT_CODE" "100" "successful prereq auth should not be mislabeled as a prereq skip"
    assert_not_contains "$RUN_STDOUT" '"status": "skip"' \
        "successful prereq auth should not emit prereq skip JSON"
    aws_call_count="$(printf '%s\n' "$RUN_AWS_CALLS" | grep -Ec '^sts get-caller-identity$' || true)"
    assert_eq "$aws_call_count" "1" "successful prereq auth should perform exactly one sts preflight call"
    assert_contains "$RUN_AWS_CALLS" "sts get-caller-identity" \
        "successful prereq auth should validate caller identity before customer flow"
    assert_contains "$RUN_AWS_CALLS" "env_s3=${expected_s3_uri}" \
        "successful prereq auth should export the expected inbox S3 URI"
    assert_contains "$RUN_AWS_CALLS" "env_domain=${expected_domain}" \
        "successful prereq auth should export the expected inbox domain"
    assert_contains "$RUN_CURL_CALLS" "/auth/register" \
        "successful prereq auth should reach the existing signup flow"
    assert_contains "$RUN_CURL_CALLS" "@${expected_domain}" \
        "signup payload should use the expected canary inbox domain"
}

test_missing_inbox_env_uses_canary_defaults_and_reaches_customer_path() {
    run_canary_case "ok" "expired" "__omit__" "__omit__"

    assert_successful_prereq_auth_reaches_signup \
        "test.flapjack.foo" \
        "s3://flapjack-cloud-releases/e2e-emails/"
}

test_secret_file_inbox_values_are_preserved() {
    run_canary_case "ok" "expired" \
        "s3://secret-file-bucket/e2e-emails/" "secret-file.example"

    assert_successful_prereq_auth_reaches_signup \
        "secret-file.example" \
        "s3://secret-file-bucket/e2e-emails/"
}

test_caller_exported_inbox_values_are_preserved() {
    run_canary_case "ok" "expired" \
        "s3://secret-file-bucket/e2e-emails/" "secret-file.example" \
        "s3://caller-export-bucket/e2e-emails/" "caller-export.example"

    assert_successful_prereq_auth_reaches_signup \
        "caller-export.example" \
        "s3://caller-export-bucket/e2e-emails/"
}

test_quiet_window_short_circuits_before_prereq_skip() {
    local aws_call_count

    run_canary_case "missing_cli" "active" \
        "s3://flapjack-cloud-releases/e2e-emails/" "test.flapjack.foo"

    assert_eq "$RUN_EXIT_CODE" "0" "quiet window should keep customer loop exit code at 0"
    assert_contains "$RUN_STDOUT" "quiet window active; skipping customer loop execution" \
        "quiet window should short-circuit customer loop execution before inbox prereq checks"
    assert_not_contains "$RUN_STDOUT" '"status": "skip"' \
        "quiet window short-circuit should not emit prereq skip JSON"

    aws_call_count="$(printf '%s\n' "$RUN_AWS_CALLS" | grep -Ec '^sts get-caller-identity$' || true)"
    assert_eq "$aws_call_count" "0" "quiet window should short-circuit before any aws CLI preflight call"
    assert_eq "$RUN_CURL_CALLS" "" "quiet window should short-circuit before customer HTTP work"
    assert_eq "$RUN_ALERT_CALLS" "" "quiet window should short-circuit before alert dispatch"
}

test_successful_prereq_auth_reaches_existing_customer_flow() {
    run_canary_case "ok" "expired" \
        "s3://flapjack-cloud-releases/e2e-emails/" "test.flapjack.foo"

    assert_successful_prereq_auth_reaches_signup \
        "test.flapjack.foo" \
        "s3://flapjack-cloud-releases/e2e-emails/"
}

main() {
    echo "=== customer_loop_synthetic_probe_env_gap_test.sh ==="

    test_missing_aws_cli_returns_skip_json_without_side_effects
    test_invalid_aws_credentials_returns_skip_json_without_customer_side_effects
    test_missing_inbox_env_uses_canary_defaults_and_reaches_customer_path
    test_secret_file_inbox_values_are_preserved
    test_caller_exported_inbox_values_are_preserved
    test_quiet_window_short_circuits_before_prereq_skip
    test_successful_prereq_auth_reaches_existing_customer_flow

    run_test_summary
}

main "$@"
