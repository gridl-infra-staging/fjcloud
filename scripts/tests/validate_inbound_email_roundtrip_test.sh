#!/usr/bin/env bash
# Tests for scripts/validate_inbound_email_roundtrip.sh
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

json_step_field() {
    local json="$1" step_name="$2" field_name="$3"
    python3 - "$json" "$step_name" "$field_name" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
step_name = sys.argv[2]
field_name = sys.argv[3]
for step in payload.get("steps", []):
    if step.get("name") == step_name:
        value = step.get(field_name, "")
        if isinstance(value, bool):
            print("true" if value else "false")
        else:
            print(str(value))
        break
else:
    print("")
PY
}

roundtrip_mock_aws_body() {
    cat <<'MOCK'
set -euo pipefail

log_path="${ROUNDTRIP_AWS_CALL_LOG:-}"
if [[ -n "$log_path" ]]; then
    echo "$*" >> "$log_path"
fi
mode="${ROUNDTRIP_MOCK_MODE:-happy}"
nonce="${INBOUND_ROUNDTRIP_NONCE:-nonce-missing}"

if [[ "${1:-}" == "sesv2" && "${2:-}" == "send-email" ]]; then
    cat <<'JSON'
{"MessageId":"mock-message-1"}
JSON
    exit 0
fi

if [[ "${1:-}" == "s3api" && "${2:-}" == "list-objects-v2" ]]; then
    case "$mode" in
        happy|auth_failure)
            cat <<JSON
{"Contents":[{"Key":"e2e-emails/${nonce}.eml"}]}
JSON
            ;;
        timeout)
            cat <<'JSON'
{"Contents":[]}
JSON
            ;;
        *)
            echo "unexpected ROUNDTRIP_MOCK_MODE for list-objects-v2: $mode" >&2
            exit 91
            ;;
    esac
    exit 0
fi

if [[ "${1:-}" == "s3api" && "${2:-}" == "get-object" ]]; then
    output_path="${@: -1}"
    case "$mode" in
        happy)
            cat > "$output_path" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: inbound test
Authentication-Results: mx.google.com; dkim=pass header.i=@flapjack.foo; spf=pass smtp.mailfrom=flapjack.foo; dmarc=pass header.from=flapjack.foo

hello
RFC822
            ;;
        auth_failure)
            cat > "$output_path" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: inbound test
Authentication-Results: mx.google.com; dkim=fail header.i=@flapjack.foo; spf=pass smtp.mailfrom=flapjack.foo; dmarc=pass header.from=flapjack.foo

hello
RFC822
            ;;
        *)
            echo "unexpected ROUNDTRIP_MOCK_MODE for get-object: $mode" >&2
            exit 92
            ;;
    esac
    cat <<'JSON'
{"ETag":"mock"}
JSON
    exit 0
fi

echo "unexpected aws command: $*" >&2
exit 93
MOCK
}

run_roundtrip() {
    local mode="$1" mock_dir="$2" call_log="$3"
    ROUNDTRIP_MOCK_MODE="$mode" \
        ROUNDTRIP_AWS_CALL_LOG="$call_log" \
        PATH="$mock_dir:$PATH" \
        SES_FROM_ADDRESS="system@flapjack.foo" \
        SES_REGION="us-east-1" \
        INBOUND_ROUNDTRIP_NONCE="stage2contractnonce" \
        INBOUND_ROUNDTRIP_S3_URI="s3://flapjack-cloud-releases/e2e-emails/" \
        INBOUND_ROUNDTRIP_POLL_MAX_ATTEMPTS="2" \
        INBOUND_ROUNDTRIP_POLL_SLEEP_SEC="0" \
        bash "$REPO_ROOT/scripts/validate_inbound_email_roundtrip.sh" 2>&1
}

test_roundtrip_happy_path_contract() {
    local mock_dir call_log output exit_code
    mock_dir="$(new_mock_command_dir "aws" "$(roundtrip_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    : > "$call_log"

    output="$(run_roundtrip happy "$mock_dir" "$call_log")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "roundtrip script should pass on happy-path fixture"
    assert_valid_json "$output" "roundtrip happy-path output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "happy-path output should report passed=true"
    assert_contains "$output" '"name":"send_probe"' "happy-path output should include send_probe step"
    assert_contains "$output" '"name":"poll_inbox_s3"' "happy-path output should include poll_inbox_s3 step"
    assert_contains "$output" '"name":"fetch_rfc822"' "happy-path output should include fetch_rfc822 step"
    assert_contains "$output" '"name":"auth_verdict"' "happy-path output should include auth_verdict step"
}

test_roundtrip_timeout_has_stage_owned_exit_code_and_json() {
    local mock_dir call_log output exit_code poll_detail
    mock_dir="$(new_mock_command_dir "aws" "$(roundtrip_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    : > "$call_log"

    output="$(run_roundtrip timeout "$mock_dir" "$call_log")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "21" "timeout path should use stage-owned timeout exit code 21"
    assert_valid_json "$output" "roundtrip timeout output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "timeout output should report passed=false"
    assert_eq "$(json_step_field "$output" "poll_inbox_s3" "passed")" "false" "timeout should fail poll_inbox_s3 step"
    poll_detail="$(json_step_field "$output" "poll_inbox_s3" "detail")"
    assert_contains "$poll_detail" "s3://flapjack-cloud-releases/e2e-emails/" "timeout detail should include canonical inbox S3 URI"
}

test_roundtrip_auth_failure_has_distinct_exit_code_and_component_name() {
    local mock_dir call_log output exit_code auth_detail
    mock_dir="$(new_mock_command_dir "aws" "$(roundtrip_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    : > "$call_log"

    output="$(run_roundtrip auth_failure "$mock_dir" "$call_log")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "22" "auth failure path should use distinct exit code 22"
    assert_valid_json "$output" "roundtrip auth-failure output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "auth-failure output should report passed=false"
    assert_eq "$(json_step_field "$output" "auth_verdict" "passed")" "false" "auth-failure should fail auth_verdict step"
    auth_detail="$(json_step_field "$output" "auth_verdict" "detail")"
    assert_contains "$auth_detail" "dkim" "auth-failure detail should name failing auth component"
}

echo "=== validate_inbound_email_roundtrip.sh tests ==="
test_roundtrip_happy_path_contract
test_roundtrip_timeout_has_stage_owned_exit_code_and_json
test_roundtrip_auth_failure_has_distinct_exit_code_and_component_name

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
