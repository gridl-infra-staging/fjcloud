#!/usr/bin/env bash
# Tests for scripts/probe_ses_simulator_send.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/probe_ses_simulator_send.sh"

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

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0

json_get_top_field() {
    local json="$1" field="$2"
    python3 - "$json" "$field" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
field = sys.argv[2]
value = payload.get(field, "")
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(str(value))
PY
}

json_get_step_field() {
    local json="$1" step_name="$2" field="$3"
    python3 - "$json" "$step_name" "$field" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
step_name = sys.argv[2]
field = sys.argv[3]
for step in payload.get("steps", []):
    if step.get("name") == step_name:
        value = step.get(field, "")
        if isinstance(value, bool):
            print("true" if value else "false")
        else:
            print(str(value))
        break
else:
    print("")
PY
}

mock_aws_body() {
    cat <<'MOCK'
set -euo pipefail

: "${SIMULATOR_SEND_AWS_CALL_LOG:?missing call log}"
echo "$*" >> "$SIMULATOR_SEND_AWS_CALL_LOG"

mode="${SIMULATOR_SEND_AWS_MODE:-success}"
if [[ "$mode" == "send_error" ]]; then
    echo "simulated send failure" >&2
    exit 1
fi

if [[ "${1:-}" == "sesv2" && "${2:-}" == "send-email" ]]; then
    if [[ "$mode" == "missing_message_id" ]]; then
        cat <<'JSON'
{"RequestId":"req-123"}
JSON
        exit 0
    fi
    cat <<JSON
{"MessageId":"${SIMULATOR_SEND_MOCK_MESSAGE_ID:-sim-msg-123}"}
JSON
    exit 0
fi

echo "unexpected aws command: $*" >&2
exit 91
MOCK
}

run_probe_with_mode() {
    local tmp_dir="$1"
    local mode="$2"
    shift 2

    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        SES_FROM_ADDRESS="noreply@flapjack.foo" \
        SES_REGION="us-east-1" \
        "$@" \
        bash "$PROBE_SCRIPT" "$mode" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

run_probe_missing_mode() {
    local tmp_dir="$1"
    shift
    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        SES_FROM_ADDRESS="noreply@flapjack.foo" \
        SES_REGION="us-east-1" \
        "$@" \
        bash "$PROBE_SCRIPT" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

setup_mock_env() {
    local tmp_dir="$1"
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/aws" "$(mock_aws_body)"
}

test_probe_sources_existing_send_and_validation_owners() {
    local contents
    contents="$(cat "$PROBE_SCRIPT")"

    assert_contains "$contents" "lib/test_inbox_helpers.sh" "probe should source shared inbox helper library"
    assert_contains "$contents" "test_inbox_send_probe_email" "probe should send through test_inbox_send_probe_email"
    assert_contains "$contents" "lib/validation_json.sh" "probe should source validation_json helper"
}

test_bounce_mode_maps_to_bounce_simulator_recipient_with_message_id() {
    local tmp_dir call_log calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/aws_calls.log"
    : > "$call_log"

    run_probe_with_mode "$tmp_dir" "bounce" \
        "SIMULATOR_SEND_AWS_CALL_LOG=$call_log" \
        "SIMULATOR_SEND_MOCK_MESSAGE_ID=bounce-mid-001"

    calls="$(cat "$call_log")"
    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "bounce mode should succeed"
    assert_valid_json "$RUN_STDOUT" "bounce mode should emit valid JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "true" "bounce mode JSON should report passed=true"
    assert_contains "$calls" "ToAddresses=bounce@simulator.amazonses.com" "bounce mode should map to bounce mailbox simulator"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "message_id='bounce-mid-001'" "bounce mode detail should include MessageId"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "bounce@simulator.amazonses.com" "bounce mode detail should include simulator recipient"
    assert_eq "$RUN_STDERR" "" "bounce mode should not write stderr on success"
}

test_complaint_mode_maps_to_complaint_simulator_recipient_with_message_id() {
    local tmp_dir call_log calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/aws_calls.log"
    : > "$call_log"

    run_probe_with_mode "$tmp_dir" "complaint" \
        "SIMULATOR_SEND_AWS_CALL_LOG=$call_log" \
        "SIMULATOR_SEND_MOCK_MESSAGE_ID=complaint-mid-009"

    calls="$(cat "$call_log")"
    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "complaint mode should succeed"
    assert_valid_json "$RUN_STDOUT" "complaint mode should emit valid JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "true" "complaint mode JSON should report passed=true"
    assert_contains "$calls" "ToAddresses=complaint@simulator.amazonses.com" "complaint mode should map to complaint mailbox simulator"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "message_id='complaint-mid-009'" "complaint mode detail should include MessageId"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "complaint@simulator.amazonses.com" "complaint mode detail should include simulator recipient"
    assert_eq "$RUN_STDERR" "" "complaint mode should not write stderr on success"
}

test_missing_mode_fails_deterministically() {
    local tmp_dir call_log call_count
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/aws_calls.log"
    : > "$call_log"

    run_probe_missing_mode "$tmp_dir" "SIMULATOR_SEND_AWS_CALL_LOG=$call_log"

    call_count="$(wc -l < "$call_log" | tr -d "[:space:]")"
    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "missing mode should fail with usage exit code"
    assert_valid_json "$RUN_STDOUT" "missing mode should emit machine-readable JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "false" "missing mode JSON should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "missing required mode" "missing mode detail should explain expected argument"
    assert_eq "$call_count" "0" "missing mode should not call aws"
}

test_invalid_mode_fails_deterministically() {
    local tmp_dir call_log call_count
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/aws_calls.log"
    : > "$call_log"

    run_probe_with_mode "$tmp_dir" "hard-bounce" "SIMULATOR_SEND_AWS_CALL_LOG=$call_log"

    call_count="$(wc -l < "$call_log" | tr -d "[:space:]")"
    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "invalid mode should fail with usage exit code"
    assert_valid_json "$RUN_STDOUT" "invalid mode should emit machine-readable JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "false" "invalid mode JSON should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "Invalid mode 'hard-bounce'" "invalid mode detail should identify invalid argument"
    assert_eq "$call_count" "0" "invalid mode should not call aws"
}

test_missing_from_address_fails_deterministically() {
    local tmp_dir call_log call_count
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/aws_calls.log"
    : > "$call_log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        SES_REGION="us-east-1" \
        SIMULATOR_SEND_AWS_CALL_LOG="$call_log" \
        bash "$PROBE_SCRIPT" bounce >"$tmp_dir/stdout.log" 2>"$tmp_dir/stderr.log" || RUN_EXIT_CODE=$?
    RUN_STDOUT="$(cat "$tmp_dir/stdout.log" 2>/dev/null || true)"

    call_count="$(wc -l < "$call_log" | tr -d "[:space:]")"
    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "missing SES_FROM_ADDRESS should fail with usage exit code"
    assert_valid_json "$RUN_STDOUT" "missing SES_FROM_ADDRESS should emit machine-readable JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "false" "missing SES_FROM_ADDRESS JSON should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "Missing SES_FROM_ADDRESS" "missing SES_FROM_ADDRESS detail should be explicit"
    assert_eq "$call_count" "0" "missing SES_FROM_ADDRESS should not call aws"
}

test_missing_region_fails_deterministically() {
    local tmp_dir call_log call_count
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/aws_calls.log"
    : > "$call_log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        SES_FROM_ADDRESS="noreply@flapjack.foo" \
        SIMULATOR_SEND_AWS_CALL_LOG="$call_log" \
        bash "$PROBE_SCRIPT" complaint >"$tmp_dir/stdout.log" 2>"$tmp_dir/stderr.log" || RUN_EXIT_CODE=$?
    RUN_STDOUT="$(cat "$tmp_dir/stdout.log" 2>/dev/null || true)"

    call_count="$(wc -l < "$call_log" | tr -d "[:space:]")"
    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "missing SES_REGION should fail with usage exit code"
    assert_valid_json "$RUN_STDOUT" "missing SES_REGION should emit machine-readable JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "false" "missing SES_REGION JSON should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "Missing SES_REGION" "missing SES_REGION detail should be explicit"
    assert_eq "$call_count" "0" "missing SES_REGION should not call aws"
}

test_send_runtime_error_surfaces_step_level_failure_detail() {
    local tmp_dir call_log
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/aws_calls.log"
    : > "$call_log"

    run_probe_with_mode "$tmp_dir" "bounce" \
        "SIMULATOR_SEND_AWS_CALL_LOG=$call_log" \
        "SIMULATOR_SEND_AWS_MODE=send_error"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "send runtime errors should fail with runtime exit code"
    assert_valid_json "$RUN_STDOUT" "send runtime error should emit machine-readable JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "false" "send runtime error JSON should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "aws sesv2 send-email failed" "send runtime error detail should explain send failure"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "simulated send failure" "send runtime error detail should preserve helper stderr"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "bounce@simulator.amazonses.com" "send runtime error detail should include target recipient"
}

test_missing_message_id_fails_with_runtime_error() {
    local tmp_dir call_log
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/aws_calls.log"
    : > "$call_log"

    run_probe_with_mode "$tmp_dir" "complaint" \
        "SIMULATOR_SEND_AWS_CALL_LOG=$call_log" \
        "SIMULATOR_SEND_AWS_MODE=missing_message_id"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "missing MessageId should fail with runtime exit code"
    assert_valid_json "$RUN_STDOUT" "missing MessageId should emit machine-readable JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "false" "missing MessageId JSON should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "response missing MessageId" "missing MessageId detail should explain malformed response"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "send_probe" "detail")" "complaint@simulator.amazonses.com" "missing MessageId detail should include target recipient"
}

main() {
    echo "=== probe_ses_simulator_send.sh tests ==="

    test_probe_sources_existing_send_and_validation_owners
    test_bounce_mode_maps_to_bounce_simulator_recipient_with_message_id
    test_complaint_mode_maps_to_complaint_simulator_recipient_with_message_id
    test_missing_mode_fails_deterministically
    test_invalid_mode_fails_deterministically
    test_missing_from_address_fails_deterministically
    test_missing_region_fails_deterministically
    test_send_runtime_error_surfaces_step_level_failure_detail
    test_missing_message_id_fails_with_runtime_error

    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
