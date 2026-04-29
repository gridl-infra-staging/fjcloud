#!/usr/bin/env bash
# Tests for scripts/stripe_webhook_replay_fixture.sh.
#
# Locks the fixture contract before implementation:
# - default check mode does not call curl
# - missing webhook secret is a blocked JSON result
# - timestamped payload + event ID generation is deterministic
# - run mode posts exactly once with expected headers and target
# - secret values are always redacted from stdout/stderr and error details

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_SCRIPT="$REPO_ROOT/scripts/stripe_webhook_replay_fixture.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0
TEST_TMP_DIR=""

cleanup_test_tmp_dir() {
    if [ -n "${TEST_TMP_DIR:-}" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup_test_tmp_dir EXIT

make_test_tmp_dir() {
    cleanup_test_tmp_dir
    TEST_TMP_DIR="$(mktemp -d)"
    mkdir -p "$TEST_TMP_DIR/bin"
}

write_mock_curl() {
    cat > "$TEST_TMP_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

: "${CURL_ARGS_LOG:?CURL_ARGS_LOG is required}"
: "${CURL_CALL_LOG:?CURL_CALL_LOG is required}"

printf 'call\n' >> "$CURL_CALL_LOG"
printf '%s\n' "$@" >> "$CURL_ARGS_LOG"
printf '\n' >> "$CURL_ARGS_LOG"

output_path=""
expect_output_arg=0
for arg in "$@"; do
    if [ "$expect_output_arg" -eq 1 ]; then
        output_path="$arg"
        expect_output_arg=0
        continue
    fi

    case "$arg" in
        -o|--output)
            expect_output_arg=1
            ;;
    esac
done

if [ -n "$output_path" ]; then
    printf '%s' "${MOCK_CURL_BODY:-}" > "$output_path"
fi

if [ "${MOCK_CURL_EXIT_CODE:-0}" -ne 0 ]; then
    if [ -n "${MOCK_CURL_STDERR:-}" ]; then
        printf '%s' "$MOCK_CURL_STDERR" >&2
    fi
    exit "${MOCK_CURL_EXIT_CODE:-0}"
fi

printf '%s' "${MOCK_CURL_HTTP_CODE:-204}"
exit "${MOCK_CURL_EXIT_CODE:-0}"
MOCK
    chmod +x "$TEST_TMP_DIR/bin/curl"
}

run_fixture_script() {
    local args=()
    local env_args=(
        "PATH=$TEST_TMP_DIR/bin:/usr/bin:/bin:/usr/local/bin"
        "HOME=$TEST_TMP_DIR"
        "TMPDIR=$TEST_TMP_DIR"
    )

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check|--run)
                args+=("$1")
                shift
                ;;
            --timestamp|--event-id|--target-url|--env-file)
                args+=("$1")
                if [ "$#" -lt 2 ]; then
                    shift
                    continue
                fi

                case "$2" in
                    --*|*=*)
                        shift
                        ;;
                    *)
                        args+=("$2")
                        shift 2
                        ;;
                esac
                ;;
            --timestamp=*|--event-id=*|--target-url=*|--env-file=*)
                args+=("$1")
                shift
                ;;
            --*)
                args+=("$1")
                shift
                ;;
            *=*)
                env_args+=("$1")
                shift
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    local stdout_file="$TEST_TMP_DIR/stdout.log"
    local stderr_file="$TEST_TMP_DIR/stderr.log"

    RUN_EXIT_CODE=0
    if [ "${#args[@]}" -gt 0 ]; then
        env -i "${env_args[@]}" bash "$FIXTURE_SCRIPT" "${args[@]}" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?
    else
        env -i "${env_args[@]}" bash "$FIXTURE_SCRIPT" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?
    fi
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

json_field() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except Exception:
    print("")
    raise SystemExit(0)
field_name = sys.argv[2]
value = payload.get(field_name, "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

assert_json_string_field() {
    local payload="$1" field_name="$2" expected="$3" msg="$4"
    local actual
    actual="$(json_field "$payload" "$field_name")"
    assert_eq "$actual" "$expected" "$msg"
}

test_default_check_mode_does_not_call_curl() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"

    run_fixture_script \
        "STRIPE_WEBHOOK_SECRET=whsec_default_check_secret" \
        "API_URL=http://127.0.0.1:4010" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log"

    local curl_call_count="0"
    if [ -f "$call_log" ]; then
        curl_call_count="$(wc -l < "$call_log" | tr -d ' ')"
    fi

    assert_eq "$RUN_EXIT_CODE" "0" "default mode should succeed"
    assert_valid_json "$RUN_STDOUT" "default mode should return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "mode" "check" "default mode should be check"
    assert_json_string_field "$RUN_STDOUT" "result" "passed" "default check mode should pass"
    assert_json_string_field "$RUN_STDOUT" "target_url" "http://127.0.0.1:4010/webhooks/stripe" \
        "default check mode should resolve target via stripe_webhook_forward_to"
    assert_json_string_field "$RUN_STDOUT" "stripe_webhook_secret" "REDACTED" \
        "default check mode should redact webhook secret value"
    assert_eq "$curl_call_count" "0" "default check mode should not call curl"
    assert_not_contains "$RUN_STDOUT" "whsec_default_check_secret" \
        "stdout should not leak raw webhook secret values"
    assert_not_contains "$RUN_STDERR" "whsec_default_check_secret" \
        "stderr should not leak raw webhook secret values"
}

test_missing_webhook_secret_returns_blocked_json() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"

    run_fixture_script \
        "STRIPE_WEBHOOK_SECRET=" \
        "API_URL=http://127.0.0.1:4010" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log"

    local curl_call_count="0"
    if [ -f "$call_log" ]; then
        curl_call_count="$(wc -l < "$call_log" | tr -d ' ')"
    fi

    assert_eq "$RUN_EXIT_CODE" "0" "missing webhook secret should be blocked without process failure"
    assert_valid_json "$RUN_STDOUT" "missing webhook secret should return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "mode" "check" "blocked result should still report check mode"
    assert_json_string_field "$RUN_STDOUT" "result" "blocked" \
        "missing webhook secret should classify as blocked"
    assert_json_string_field "$RUN_STDOUT" "classification" "stripe_webhook_secret_missing" \
        "missing webhook secret should use stable blocker classification"
    assert_json_string_field "$RUN_STDOUT" "stripe_webhook_secret" "<missing>" \
        "missing webhook secret should emit explicit redacted missing marker"
    assert_eq "$curl_call_count" "0" "blocked check mode should not call curl"
    assert_not_contains "$RUN_STDOUT" "whsec_" "blocked JSON should never include raw webhook secret prefixes"
    assert_not_contains "$RUN_STDERR" "whsec_" "stderr should never include raw webhook secret prefixes"
}

test_timestamp_makes_payload_and_event_id_deterministic() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"
    local timestamp="1704067200"

    run_fixture_script \
        --check \
        --timestamp "$timestamp" \
        "STRIPE_WEBHOOK_SECRET=whsec_deterministic_secret" \
        "API_URL=http://127.0.0.1:4010" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log"

    local first_payload first_event first_signature
    first_payload="$(json_field "$RUN_STDOUT" "payload")"
    first_event="$(json_field "$RUN_STDOUT" "event_id")"
    first_signature="$(json_field "$RUN_STDOUT" "stripe_signature")"

    run_fixture_script \
        --check \
        --timestamp "$timestamp" \
        "STRIPE_WEBHOOK_SECRET=whsec_deterministic_secret" \
        "API_URL=http://127.0.0.1:4010" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log"

    local second_payload second_event second_signature
    second_payload="$(json_field "$RUN_STDOUT" "payload")"
    second_event="$(json_field "$RUN_STDOUT" "event_id")"
    second_signature="$(json_field "$RUN_STDOUT" "stripe_signature")"

    assert_eq "$first_payload" "$second_payload" \
        "timestamped payload should be deterministic across runs"
    assert_eq "$first_event" "$second_event" \
        "timestamped event ID should be deterministic across runs"
    assert_eq "$first_signature" "$second_signature" \
        "timestamped Stripe signature should be deterministic across runs"
    assert_not_contains "$RUN_STDOUT" "whsec_deterministic_secret" \
        "deterministic check output should redact webhook secret value"
    assert_not_contains "$RUN_STDERR" "whsec_deterministic_secret" \
        "deterministic check stderr should not leak webhook secret value"
}

test_run_mode_posts_once_with_expected_headers_and_target() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"

    run_fixture_script \
        --run \
        --timestamp 1704067200 \
        "STRIPE_WEBHOOK_SECRET=whsec_run_mode_secret" \
        "API_URL=http://127.0.0.1:4010" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log" \
        "MOCK_CURL_HTTP_CODE=204" \
        "MOCK_CURL_BODY={\"ok\":true}"

    local curl_call_count="0"
    if [ -f "$call_log" ]; then
        curl_call_count="$(wc -l < "$call_log" | tr -d ' ')"
    fi
    local curl_args=""
    if [ -f "$args_log" ]; then
        curl_args="$(cat "$args_log")"
    fi

    assert_eq "$RUN_EXIT_CODE" "0" "run mode should pass when webhook endpoint returns 2xx"
    assert_valid_json "$RUN_STDOUT" "run mode should return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "mode" "run" "run mode should report mode=run"
    assert_json_string_field "$RUN_STDOUT" "result" "passed" "run mode 2xx should pass"
    assert_json_string_field "$RUN_STDOUT" "target_url" "http://127.0.0.1:4010/webhooks/stripe" \
        "run mode should resolve API target ending in /webhooks/stripe"
    assert_eq "$curl_call_count" "1" "run mode should post exactly once"
    assert_contains "$curl_args" "http://127.0.0.1:4010/webhooks/stripe" \
        "run mode should post to the resolved /webhooks/stripe target"
    assert_contains "$curl_args" "Content-Type: application/json" \
        "run mode should send JSON content type header"
    assert_contains "$curl_args" "Stripe-Signature: t=1704067200,v1=" \
        "run mode should send Stripe-Signature header using timestamped contract"
    assert_contains "$curl_args" '"type":"customer.updated"' \
        "run mode should use unsupported non-mutating customer.updated event payload"
    assert_not_contains "$RUN_STDOUT" "whsec_run_mode_secret" \
        "run mode stdout should not leak webhook secret value"
    assert_not_contains "$RUN_STDERR" "whsec_run_mode_secret" \
        "run mode stderr should not leak webhook secret value"
}

test_run_mode_supports_invoice_payment_failed_retry_payload() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"

    run_fixture_script \
        --run \
        --allow-staging-target \
        --target-url "https://api.flapjack.foo/webhooks/stripe" \
        --timestamp 1704067200 \
        --event-id "evt_retry_alert_fixture" \
        --event-type "invoice.payment_failed" \
        --invoice-id "in_retry_fixture_01" \
        --next-payment-attempt "1708300800" \
        --attempt-count "2" \
        "STRIPE_WEBHOOK_SECRET=whsec_retry_payload_secret" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log" \
        "MOCK_CURL_HTTP_CODE=200" \
        "MOCK_CURL_BODY={\"ok\":true}"

    local curl_call_count="0"
    if [ -f "$call_log" ]; then
        curl_call_count="$(wc -l < "$call_log" | tr -d ' ')"
    fi
    local curl_args=""
    if [ -f "$args_log" ]; then
        curl_args="$(cat "$args_log")"
    fi

    assert_eq "$RUN_EXIT_CODE" "0" "invoice.payment_failed replay should pass on 2xx"
    assert_valid_json "$RUN_STDOUT" "invoice.payment_failed replay should return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "result" "passed" \
        "invoice.payment_failed replay should report passed result"
    assert_eq "$curl_call_count" "1" "invoice.payment_failed replay should post exactly once"
    assert_contains "$curl_args" '"type":"invoice.payment_failed"' \
        "invoice.payment_failed replay should send invoice.payment_failed event type"
    assert_contains "$curl_args" '"id":"in_retry_fixture_01"' \
        "invoice.payment_failed replay should send invoice id in data.object.id"
    assert_contains "$curl_args" '"next_payment_attempt":1708300800' \
        "invoice.payment_failed replay should send non-null next_payment_attempt"
    assert_contains "$curl_args" '"attempt_count":2' \
        "invoice.payment_failed replay should send attempt_count for retry alert contract"
    assert_not_contains "$RUN_STDOUT" "whsec_retry_payload_secret" \
        "invoice.payment_failed replay output should redact webhook secret"
    assert_not_contains "$RUN_STDERR" "whsec_retry_payload_secret" \
        "invoice.payment_failed replay stderr should not leak webhook secret"
}

test_run_mode_non_2xx_fails_closed_and_redacts_error_detail() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"
    local configured_secret="whsec_configured_secret"
    local echoed_secret="whsec_remote_echo_secret"

    run_fixture_script \
        --run \
        --timestamp 1704067200 \
        "STRIPE_WEBHOOK_SECRET=$configured_secret" \
        "API_URL=http://127.0.0.1:4010" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log" \
        "MOCK_CURL_HTTP_CODE=500" \
        "MOCK_CURL_BODY={\"error\":\"remote echoed $echoed_secret\"}"

    assert_eq "$RUN_EXIT_CODE" "1" "run mode should fail closed on non-2xx webhook responses"
    assert_valid_json "$RUN_STDOUT" "non-2xx run mode should return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "result" "failed" "non-2xx run mode should report failed result"
    assert_json_string_field "$RUN_STDOUT" "classification" "webhook_post_failed" \
        "non-2xx run mode should emit stable failure classification"
    assert_not_contains "$RUN_STDOUT" "$configured_secret" \
        "non-2xx run mode JSON should redact configured webhook secret values"
    assert_not_contains "$RUN_STDOUT" "$echoed_secret" \
        "non-2xx run mode JSON should redact echoed webhook secret values"
    assert_not_contains "$RUN_STDERR" "$configured_secret" \
        "non-2xx run mode stderr should not leak configured webhook secret values"
    assert_not_contains "$RUN_STDERR" "$echoed_secret" \
        "non-2xx run mode stderr should not leak echoed webhook secret values"
    assert_not_contains "$RUN_STDOUT" "whsec_" \
        "non-2xx run mode JSON should never include raw webhook secret prefixes"
    assert_not_contains "$RUN_STDERR" "whsec_" \
        "non-2xx run mode stderr should never include raw webhook secret prefixes"
}

test_run_mode_transport_failure_returns_machine_readable_json() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"
    local configured_secret="whsec_transport_secret"
    local echoed_secret="whsec_transport_echo_secret"

    run_fixture_script \
        --run \
        --timestamp 1704067200 \
        "STRIPE_WEBHOOK_SECRET=$configured_secret" \
        "API_URL=http://127.0.0.1:4010" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log" \
        "MOCK_CURL_EXIT_CODE=6" \
        "MOCK_CURL_STDERR=curl: (6) Could not resolve host: 127.0.0.1 $echoed_secret"

    assert_eq "$RUN_EXIT_CODE" "1" "transport failure should fail with script exit code 1"
    assert_valid_json "$RUN_STDOUT" "transport failure should still return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "result" "failed" \
        "transport failure should report failed result"
    assert_json_string_field "$RUN_STDOUT" "classification" "webhook_post_request_failed" \
        "transport failure should emit stable request-failure classification"
    assert_not_contains "$RUN_STDOUT" "$configured_secret" \
        "transport failure JSON should redact configured webhook secret values"
    assert_not_contains "$RUN_STDOUT" "$echoed_secret" \
        "transport failure JSON should redact echoed webhook secret values"
    assert_not_contains "$RUN_STDERR" "$configured_secret" \
        "transport failure stderr should not leak configured webhook secret values"
    assert_not_contains "$RUN_STDERR" "$echoed_secret" \
        "transport failure stderr should not leak echoed webhook secret values"
    assert_not_contains "$RUN_STDOUT" "whsec_" \
        "transport failure JSON should never include raw webhook secret prefixes"
    assert_not_contains "$RUN_STDERR" "whsec_" \
        "transport failure stderr should never include raw webhook secret prefixes"
}

test_missing_flag_value_returns_machine_readable_json() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"

    run_fixture_script \
        --target-url \
        "STRIPE_WEBHOOK_SECRET=whsec_parse_case_secret" \
        "API_URL=http://127.0.0.1:4010" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log"

    assert_eq "$RUN_EXIT_CODE" "1" "missing flag value should fail with script exit code 1"
    assert_valid_json "$RUN_STDOUT" "missing flag value should still return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "result" "failed" \
        "missing flag value should produce failed result"
    assert_json_string_field "$RUN_STDOUT" "classification" "cli_argument_missing_value" \
        "missing flag value should emit stable parse classification"
    assert_not_contains "$RUN_STDERR" "Usage:" \
        "missing flag value should not emit raw usage text to stderr"
    assert_not_contains "$RUN_STDERR" "ERROR:" \
        "missing flag value should not emit raw parse errors to stderr"
}

test_unknown_flag_returns_machine_readable_json() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"

    run_fixture_script \
        --unexpected-flag \
        "STRIPE_WEBHOOK_SECRET=whsec_parse_case_secret" \
        "API_URL=http://127.0.0.1:4010" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log"

    assert_eq "$RUN_EXIT_CODE" "1" "unknown flag should fail with script exit code 1"
    assert_valid_json "$RUN_STDOUT" "unknown flag should still return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "result" "failed" \
        "unknown flag should produce failed result"
    assert_json_string_field "$RUN_STDOUT" "classification" "cli_argument_unknown" \
        "unknown flag should emit stable parse classification"
    assert_not_contains "$RUN_STDERR" "Usage:" \
        "unknown flag should not emit raw usage text to stderr"
    assert_not_contains "$RUN_STDERR" "ERROR:" \
        "unknown flag should not emit raw parse errors to stderr"
}

test_run_mode_rejects_non_local_target_url() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"

    run_fixture_script \
        --run \
        --target-url "https://api.example.test/webhooks/stripe" \
        "STRIPE_WEBHOOK_SECRET=whsec_non_local_target_secret" \
        "API_URL=http://127.0.0.1:4010" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log"

    local curl_call_count="0"
    if [ -f "$call_log" ]; then
        curl_call_count="$(wc -l < "$call_log" | tr -d ' ')"
    fi

    assert_eq "$RUN_EXIT_CODE" "1" "non-local run target should fail closed"
    assert_valid_json "$RUN_STDOUT" "non-local run target should still return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "result" "failed" \
        "non-local run target should produce failed result"
    assert_json_string_field "$RUN_STDOUT" "classification" "target_url_invalid" \
        "non-local run target should emit stable target classification"
    assert_eq "$curl_call_count" "0" "non-local run target should be rejected before curl executes"
    assert_not_contains "$RUN_STDOUT" "whsec_non_local_target_secret" \
        "non-local target rejection should redact webhook secret values"
    assert_not_contains "$RUN_STDERR" "whsec_non_local_target_secret" \
        "non-local target rejection stderr should not leak webhook secret values"
}

test_run_mode_allow_staging_target_posts_once_with_expected_signature() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"
    local staging_api_url="https://api.flapjack.foo"

    run_fixture_script \
        --run \
        --allow-staging-target \
        --timestamp 1704067200 \
        "STRIPE_WEBHOOK_SECRET=whsec_staging_allowlist_secret" \
        "API_URL=$staging_api_url" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log" \
        "MOCK_CURL_HTTP_CODE=204" \
        "MOCK_CURL_BODY={\"ok\":true}"

    local curl_call_count="0"
    if [ -f "$call_log" ]; then
        curl_call_count="$(wc -l < "$call_log" | tr -d ' ')"
    fi
    local curl_args=""
    if [ -f "$args_log" ]; then
        curl_args="$(cat "$args_log")"
    fi

    assert_eq "$RUN_EXIT_CODE" "0" "run mode should allow sanctioned staging target when opt-in flag is set"
    assert_valid_json "$RUN_STDOUT" "staging opt-in run mode should return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "result" "passed" \
        "staging opt-in run mode should pass on 2xx response"
    assert_json_string_field "$RUN_STDOUT" "target_url" "${staging_api_url}/webhooks/stripe" \
        "staging opt-in run mode should resolve the sanctioned staging webhook target"
    assert_eq "$curl_call_count" "1" "staging opt-in run mode should post exactly once"
    assert_contains "$curl_args" "${staging_api_url}/webhooks/stripe" \
        "staging opt-in run mode should post to sanctioned staging target"
    assert_contains "$curl_args" "Stripe-Signature: t=1704067200,v1=" \
        "staging opt-in run mode should include Stripe-Signature header"
    assert_not_contains "$RUN_STDOUT" "whsec_staging_allowlist_secret" \
        "staging opt-in run mode should redact webhook secret values"
    assert_not_contains "$RUN_STDERR" "whsec_staging_allowlist_secret" \
        "staging opt-in run mode stderr should not leak webhook secret values"
}

test_run_mode_allow_staging_target_still_rejects_unsanctioned_remote() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"

    run_fixture_script \
        --run \
        --allow-staging-target \
        --target-url "https://api.example.test/webhooks/stripe" \
        "STRIPE_WEBHOOK_SECRET=whsec_non_sanctioned_target_secret" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log"

    local curl_call_count="0"
    if [ -f "$call_log" ]; then
        curl_call_count="$(wc -l < "$call_log" | tr -d ' ')"
    fi

    assert_eq "$RUN_EXIT_CODE" "1" "opt-in should still reject unsanctioned remote targets"
    assert_valid_json "$RUN_STDOUT" "unsanctioned remote opt-in run should still return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "classification" "target_url_invalid" \
        "unsanctioned remote opt-in run should retain stable target-url invalid classification"
    assert_eq "$curl_call_count" "0" "unsanctioned remote opt-in target should be rejected before curl executes"
}

test_malformed_explicit_env_file_returns_machine_readable_json() {
    make_test_tmp_dir
    write_mock_curl

    local call_log="$TEST_TMP_DIR/curl_calls.log"
    local args_log="$TEST_TMP_DIR/curl_args.log"
    local malformed_env="$TEST_TMP_DIR/malformed.env"
    cat > "$malformed_env" <<'ENV'
STRIPE_WEBHOOK_SECRET=whsec_fixture_secret
this is not valid env syntax
ENV

    run_fixture_script \
        --check \
        --env-file "$malformed_env" \
        "API_URL=http://127.0.0.1:4010" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log"

    local curl_call_count="0"
    if [ -f "$call_log" ]; then
        curl_call_count="$(wc -l < "$call_log" | tr -d ' ')"
    fi

    assert_eq "$RUN_EXIT_CODE" "1" "malformed explicit env file should fail with exit code 1"
    assert_valid_json "$RUN_STDOUT" "malformed explicit env file should still return valid JSON"
    assert_json_string_field "$RUN_STDOUT" "result" "failed" \
        "malformed explicit env file should produce failed result"
    assert_json_string_field "$RUN_STDOUT" "classification" "explicit_env_file_invalid" \
        "malformed explicit env file should emit stable classification"
    assert_eq "$curl_call_count" "0" "malformed explicit env file should not call curl"
    assert_not_contains "$RUN_STDERR" "Unsupported syntax in" \
        "malformed explicit env file should avoid raw loader stderr"
    assert_not_contains "$RUN_STDOUT" "whsec_fixture_secret" \
        "malformed explicit env output should redact webhook secret values"
}

echo "=== stripe_webhook_replay_fixture.sh tests ==="
test_default_check_mode_does_not_call_curl
test_missing_webhook_secret_returns_blocked_json
test_timestamp_makes_payload_and_event_id_deterministic
test_run_mode_posts_once_with_expected_headers_and_target
test_run_mode_non_2xx_fails_closed_and_redacts_error_detail
test_run_mode_transport_failure_returns_machine_readable_json
test_missing_flag_value_returns_machine_readable_json
test_unknown_flag_returns_machine_readable_json
test_run_mode_rejects_non_local_target_url
test_run_mode_allow_staging_target_posts_once_with_expected_signature
test_run_mode_allow_staging_target_still_rejects_unsanctioned_remote
test_run_mode_supports_invoice_payment_failed_retry_payload
test_malformed_explicit_env_file_returns_machine_readable_json
run_test_summary
