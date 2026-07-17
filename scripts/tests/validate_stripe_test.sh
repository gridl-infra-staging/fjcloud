#!/usr/bin/env bash
# Tests for scripts/validate-stripe.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROTATION_RUNBOOK_FILE="$REPO_ROOT/docs/runbooks/secret_rotation.md"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

json_step_detail() {
    local json="$1" step_name="$2"
    python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for step in d.get('steps', []):
    if step.get('name') == '$step_name':
        print(step.get('detail', ''))
        break
else:
    print('')
" <<< "$json" 2>/dev/null || echo ""
}

write_mock_curl_with_sequence() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${STRIPE_TEST_CALL_LOG:-}" ]; then
    printf '%s\n' "$@" >> "$STRIPE_TEST_CALL_LOG"
    printf '\n' >> "$STRIPE_TEST_CALL_LOG"
fi

header_file=""
body_file=""
write_format=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -D)
            header_file="$2"
            shift 2
            ;;
        -o)
            body_file="$2"
            shift 2
            ;;
        -w)
            write_format="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [ -z "${STRIPE_TEST_RESPONSE_FILE:-}" ]; then
    echo "missing STRIPE_TEST_RESPONSE_FILE" >&2
    exit 1
fi

python3 - "$STRIPE_TEST_RESPONSE_FILE" "$header_file" "$body_file" "$write_format" <<'PY'
import json
import sys
from pathlib import Path

response_file, header_file, body_file, write_format = sys.argv[1:5]
path = Path(response_file)
data = json.loads(path.read_text())
idx = int(data.get("index", 0))
responses = data["responses"]
if idx >= len(responses):
    raise SystemExit("mock response sequence exhausted")
response = responses[idx]
data["index"] = idx + 1
path.write_text(json.dumps(data))

headers = response.get("headers", {})
body = response.get("body", "")
status = str(response.get("status", "200"))

if header_file:
    with open(header_file, "w", encoding="utf-8") as fh:
        for key, value in headers.items():
            fh.write(f"{key}: {value}\r\n")

if body_file:
    with open(body_file, "w", encoding="utf-8") as fh:
        fh.write(body)

if write_format == "%{http_code}":
    sys.stdout.write(status)
PY
MOCK
    chmod +x "$path"
}

test_validate_stripe_fails_when_key_unset() {
    local output exit_code
    output="$(env -u STRIPE_SECRET_KEY -u STRIPE_TEST_SECRET_KEY bash "$REPO_ROOT/scripts/validate-stripe.sh" 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe should fail when STRIPE_SECRET_KEY is unset"
    assert_valid_json "$output" "validate-stripe unset-key output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe unset-key JSON should report passed=false"
    assert_contains "$output" "require_stripe_secret_key" "validate-stripe unset-key output should include canonical key check step"
    assert_contains "$(json_step_detail "$output" "require_stripe_secret_key")" "STRIPE_SECRET_KEY" \
        "validate-stripe unset-key detail should reference canonical env var"
}

test_validate_stripe_fails_gracefully_with_invalid_key() {
    local mock_dir response_file
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":401,"body":"{\"error\":{\"type\":\"authentication_error\",\"message\":\"Invalid API Key provided\"}}"}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    local output exit_code
    output="$(STRIPE_SECRET_KEY='sk_test_invalid' STRIPE_TEST_RESPONSE_FILE="$response_file" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-stripe should fail with invalid Stripe key"
    assert_valid_json "$output" "validate-stripe invalid-key output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe invalid-key JSON should report passed=false"
    assert_contains "$output" "create_customer" "validate-stripe invalid-key output should include create_customer step"
    assert_contains "$(json_step_detail "$output" "create_customer")" "HTTP 401" \
        "validate-stripe invalid-key machine-readable detail should include HTTP 401"
}

test_validate_stripe_alias_fallback_when_canonical_missing() {
    local mock_dir response_file
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":401,"body":"{\"error\":{\"type\":\"authentication_error\",\"message\":\"Invalid API Key provided\"}}"}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    local output exit_code
    output="$(env -u STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY='sk_test_alias_invalid' STRIPE_TEST_RESPONSE_FILE="$response_file" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-stripe alias compatibility path should still produce machine-readable failure output"
    assert_valid_json "$output" "validate-stripe alias-path output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe alias-path JSON should report passed=false"
    assert_contains "$output" "create_customer" "validate-stripe alias-path output should include create_customer step"
    assert_contains "$(json_step_detail "$output" "create_customer")" "HTTP 401" \
        "validate-stripe alias-path machine-readable detail should include HTTP 401"
}

test_validate_stripe_accepts_restricted_canonical_key() {
    local mock_dir response_file output
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":200,"body":"{\"id\":\"cus_mock_customer\"}"},
  {"status":200,"body":"{\"id\":\"pm_attached_customer_card\"}"},
  {"status":200,"body":"{\"id\":\"cus_mock_customer\"}"},
  {"status":200,"body":"{\"id\":\"ii_mock_invoice_item\"}"},
  {"status":200,"body":"{\"id\":\"in_mock_invoice\"}"},
  {"status":200,"body":"{\"status\":\"paid\"}"}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    output="$(STRIPE_SECRET_KEY='rk_test_mock' STRIPE_TEST_RESPONSE_FILE="$response_file" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh")"

    assert_valid_json "$output" "validate-stripe rk_test canonical-key output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "validate-stripe rk_test canonical-key flow should report passed=true"

    rm -rf "$mock_dir"
}

test_validate_stripe_accepts_restricted_alias_key() {
    local mock_dir response_file output
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":200,"body":"{\"id\":\"cus_mock_customer\"}"},
  {"status":200,"body":"{\"id\":\"pm_attached_customer_card\"}"},
  {"status":200,"body":"{\"id\":\"cus_mock_customer\"}"},
  {"status":200,"body":"{\"id\":\"ii_mock_invoice_item\"}"},
  {"status":200,"body":"{\"id\":\"in_mock_invoice\"}"},
  {"status":200,"body":"{\"status\":\"paid\"}"}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    output="$(env -u STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY='rk_test_alias_mock' STRIPE_TEST_RESPONSE_FILE="$response_file" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh")"

    assert_valid_json "$output" "validate-stripe rk_test alias-key output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "validate-stripe rk_test alias-key flow should report passed=true"

    rm -rf "$mock_dir"
}

test_validate_stripe_rejects_live_canonical_key_before_api_calls() {
    local mock_dir
    local call_log
    mock_dir="$(mktemp -d)"
    call_log="$mock_dir/curl_called.log"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo "called" >> "$STRIPE_TEST_CALL_LOG"
echo '{"id":"cus_mock"}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(STRIPE_SECRET_KEY='sk_live_123456' STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe should reject live canonical key before API calls"
    assert_valid_json "$output" "validate-stripe live canonical-key output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe live canonical-key JSON should report passed=false"
    assert_contains "$output" "require_test_mode_stripe_secret_key" "validate-stripe live canonical-key output should include test-mode key guard step"
    assert_contains "$(json_step_detail "$output" "require_test_mode_stripe_secret_key")" "sk_test_" \
        "validate-stripe live canonical-key detail should require sk_test_ prefix"
    if [ -f "$call_log" ]; then
        fail "validate-stripe should not call curl when canonical key is sk_live_"
    else
        pass "validate-stripe should not call curl when canonical key is sk_live_"
    fi

    rm -rf "$mock_dir"
}

test_validate_stripe_rejects_live_alias_key_before_api_calls() {
    local mock_dir
    local call_log
    mock_dir="$(mktemp -d)"
    call_log="$mock_dir/curl_called.log"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo "called" >> "$STRIPE_TEST_CALL_LOG"
echo '{"id":"cus_mock"}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(env -u STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY='sk_live_alias_123456' STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe should reject live alias key before API calls"
    assert_valid_json "$output" "validate-stripe live alias-key output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe live alias-key JSON should report passed=false"
    assert_contains "$output" "require_test_mode_stripe_secret_key" "validate-stripe live alias-key output should include test-mode key guard step"
    assert_contains "$(json_step_detail "$output" "require_test_mode_stripe_secret_key")" "sk_test_" \
        "validate-stripe live alias-key detail should require sk_test_ prefix"
    if [ -f "$call_log" ]; then
        fail "validate-stripe should not call curl when alias key resolves to sk_live_"
    else
        pass "validate-stripe should not call curl when alias key resolves to sk_live_"
    fi

    rm -rf "$mock_dir"
}

test_validate_stripe_rejects_restricted_live_canonical_key_before_api_calls() {
    local mock_dir
    local call_log
    mock_dir="$(mktemp -d)"
    call_log="$mock_dir/curl_called.log"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo "called" >> "$STRIPE_TEST_CALL_LOG"
echo '{"id":"cus_mock"}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(STRIPE_SECRET_KEY='rk_live_123456' STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe should reject rk_live canonical key before API calls"
    assert_valid_json "$output" "validate-stripe rk_live canonical-key output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe rk_live canonical-key JSON should report passed=false"
    assert_contains "$output" "require_test_mode_stripe_secret_key" "validate-stripe rk_live canonical-key output should include test-mode key guard step"
    assert_contains "$(json_step_detail "$output" "require_test_mode_stripe_secret_key")" "rk_test_" \
        "validate-stripe rk_live canonical-key detail should require rk_test_ allowance text"
    if [ -f "$call_log" ]; then
        fail "validate-stripe should not call curl when canonical key is rk_live_"
    else
        pass "validate-stripe should not call curl when canonical key is rk_live_"
    fi

    rm -rf "$mock_dir"
}

test_validate_stripe_rejects_restricted_live_alias_key_before_api_calls() {
    local mock_dir
    local call_log
    mock_dir="$(mktemp -d)"
    call_log="$mock_dir/curl_called.log"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo "called" >> "$STRIPE_TEST_CALL_LOG"
echo '{"id":"cus_mock"}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(env -u STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY='rk_live_alias_123456' STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe should reject rk_live alias key before API calls"
    assert_valid_json "$output" "validate-stripe rk_live alias-key output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe rk_live alias-key JSON should report passed=false"
    assert_contains "$output" "require_test_mode_stripe_secret_key" "validate-stripe rk_live alias-key output should include test-mode key guard step"
    assert_contains "$(json_step_detail "$output" "require_test_mode_stripe_secret_key")" "rk_test_" \
        "validate-stripe rk_live alias-key detail should require rk_test_ allowance text"
    if [ -f "$call_log" ]; then
        fail "validate-stripe should not call curl when alias key resolves to rk_live_"
    else
        pass "validate-stripe should not call curl when alias key resolves to rk_live_"
    fi

    rm -rf "$mock_dir"
}

test_validate_stripe_default_mode_keeps_test_mode_step_names() {
    local output exit_code
    output="$(STRIPE_SECRET_KEY='sk_live_default_mode_reject' bash "$REPO_ROOT/scripts/validate-stripe.sh" 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe default mode should still reject sk_live_ keys"
    assert_valid_json "$output" "validate-stripe default-mode live-key output should be valid JSON"
    assert_contains "$output" "require_test_mode_stripe_secret_key" "default mode should preserve require_test_mode_stripe_secret_key step naming"
    assert_not_contains "$output" "live_cutover_mode_enabled" "default mode output should not include live-cutover success evidence step"
    assert_not_contains "$output" "require_live_cutover_control" "default mode should not require cutover control"
}

test_validate_stripe_live_cutover_requires_control() {
    local mock_dir
    local call_log
    mock_dir="$(mktemp -d)"
    call_log="$mock_dir/curl_called.log"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo "called" >> "$STRIPE_TEST_CALL_LOG"
echo '{"id":"cus_mock"}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(STRIPE_SECRET_KEY='sk_live_cutover_requires_control' STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" --live-cutover 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe live-cutover invocation should fail without explicit cutover control"
    assert_valid_json "$output" "validate-stripe missing cutover control output should be valid JSON"
    assert_contains "$output" "require_live_cutover_control" "live-cutover mode should emit explicit cutover control step on failure"
    if [ -f "$call_log" ]; then
        fail "validate-stripe should not call curl when live-cutover control is missing"
    else
        pass "validate-stripe should fail before curl when live-cutover control is missing"
    fi

    rm -rf "$mock_dir"
}

test_validate_stripe_live_cutover_allows_live_keys_with_control() {
    local mock_dir response_file call_log output
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    call_log="$mock_dir/curl_args.log"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":200,"body":"{\"available\":[]}","headers":{"Request-Id":"req_live_cutover_balance"}}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    output="$(STRIPE_SECRET_KEY='rk_live_cutover_ok' STRIPE_LIVE_CUTOVER=1 STRIPE_TEST_RESPONSE_FILE="$response_file" STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" --live-cutover)"

    assert_valid_json "$output" "validate-stripe live-cutover success output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "validate-stripe live-cutover flow should report passed=true"
    assert_contains "$output" "live_cutover_mode_enabled" "validate-stripe live-cutover output should include explicit evidence step"
    assert_not_contains "$output" "require_test_mode_stripe_secret_key" "live-cutover success should not emit default test-mode failure step"
    assert_contains "$(cat "$call_log")" "https://api.stripe.com/v1/balance" \
        "validate-stripe live-cutover success should probe Stripe auth via /v1/balance"
    assert_not_contains "$(cat "$call_log")" "/v1/customers" \
        "validate-stripe live-cutover success should stay non-mutating"
    assert_not_contains "$(cat "$call_log")" "/v1/invoices" \
        "validate-stripe live-cutover success should not create invoice resources"
    assert_not_contains "$(cat "$call_log")" "pm_card_visa" \
        "validate-stripe live-cutover success should never touch test payment method fixtures"

    rm -rf "$mock_dir"
}

test_validate_stripe_live_cutover_rejects_test_keys() {
    local mock_dir
    local call_log
    mock_dir="$(mktemp -d)"
    call_log="$mock_dir/curl_called.log"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo "called" >> "$STRIPE_TEST_CALL_LOG"
echo '{"id":"cus_mock"}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(STRIPE_SECRET_KEY='sk_test_wrong_for_live_cutover' STRIPE_LIVE_CUTOVER=1 STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" --live-cutover 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe live-cutover mode should reject sk_test_ keys"
    assert_valid_json "$output" "validate-stripe live-cutover test-key rejection should be valid JSON"
    assert_contains "$output" "require_live_cutover_stripe_secret_key" "live-cutover mode should emit a dedicated live-key prefix requirement step"
    if [ -f "$call_log" ]; then
        fail "validate-stripe should not call curl when live-cutover mode rejects sk_test_ key"
    else
        pass "validate-stripe should reject sk_test_ key before curl in live-cutover mode"
    fi

    rm -rf "$mock_dir"
}

test_validate_stripe_live_cutover_avoids_test_payment_method_token() {
    local mock_dir
    local call_log
    mock_dir="$(mktemp -d)"
    call_log="$mock_dir/curl_args.log"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >> "$STRIPE_TEST_CALL_LOG"

for arg in "$@"; do
    if [ "$arg" = "https://api.stripe.com/v1/payment_methods/pm_card_visa/attach" ]; then
        echo "unexpected test-mode payment method attach endpoint in live-cutover mode" >&2
        exit 99
    fi
done

header_file=""
body_file=""
write_format=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -D)
            header_file="$2"
            shift 2
            ;;
        -o)
            body_file="$2"
            shift 2
            ;;
        -w)
            write_format="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [ -n "$header_file" ]; then
    printf 'Request-Id: req_live_cutover\n' > "$header_file"
fi
if [ -n "$body_file" ]; then
    printf '{"available":[]}' > "$body_file"
fi
if [ "$write_format" = "%{http_code}" ]; then
    printf '200'
fi
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(STRIPE_SECRET_KEY='rk_live_cutover_probe' STRIPE_LIVE_CUTOVER=1 STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" --live-cutover 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "validate-stripe live-cutover mode should pass without touching test-mode payment method endpoints"
    assert_valid_json "$output" "validate-stripe live-cutover no-test-token output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "validate-stripe live-cutover no-test-token flow should report passed=true"
    assert_contains "$output" "live_cutover_mode_enabled" "live-cutover output should include explicit cutover evidence step"
    assert_contains "$(cat "$call_log")" "https://api.stripe.com/v1/balance" "live-cutover mode should perform a non-mutating Stripe balance auth check"
    assert_not_contains "$(cat "$call_log")" "pm_card_visa" "live-cutover mode should never call pm_card_visa endpoints"

    rm -rf "$mock_dir"
}

test_validate_stripe_uses_attached_payment_method_id_for_default() {
    local mock_dir response_file output
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":200,"body":"{\"id\":\"cus_mock_customer\"}","headers":{"Request-Id":"req_create_customer"}},
  {"status":200,"body":"{\"id\":\"pm_attached_customer_card\"}","headers":{"Request-Id":"req_attach_payment_method"}},
  {"status":200,"body":"{\"id\":\"cus_mock_customer\"}","headers":{"Request-Id":"req_set_default"}},
  {"status":200,"body":"{\"id\":\"ii_mock_invoice_item\"}","headers":{"Request-Id":"req_invoice_item"}},
  {"status":200,"body":"{\"id\":\"in_mock_invoice\"}","headers":{"Request-Id":"req_create_invoice"}},
  {"status":200,"body":"{\"status\":\"paid\"}","headers":{"Request-Id":"req_pay_invoice"}}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    output="$(STRIPE_SECRET_KEY='sk_test_mock' STRIPE_TEST_RESPONSE_FILE="$response_file" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh")"

    assert_valid_json "$output" "validate-stripe success-path output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "validate-stripe success-path JSON should report passed=true"
    assert_contains "$(json_step_detail "$output" "attach_payment_method")" "pm_attached_customer_card" \
        "validate-stripe should use the attached payment method id in success details"

    rm -rf "$mock_dir"
}

test_validate_stripe_surfaces_stripe_error_context() {
    local mock_dir response_file output exit_code
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":401,"body":"{\"error\":{\"type\":\"authentication_error\",\"code\":\"api_key_expired\",\"message\":\"Invalid API Key provided\",\"request_log_url\":\"https://dashboard.stripe.com/test/workbench/logs?object=req_mock_create_customer\"}}","headers":{"Request-Id":"req_mock_create_customer"}}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    output="$(STRIPE_SECRET_KEY='sk_test_invalid' STRIPE_TEST_RESPONSE_FILE="$response_file" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe should fail with mock Stripe error context"
    assert_valid_json "$output" "validate-stripe Stripe-error output should be valid JSON"
    assert_contains "$(json_step_detail "$output" "create_customer")" "request_id=req_mock_create_customer" \
        "validate-stripe should include the Stripe request id in failure details"
    assert_contains "$(json_step_detail "$output" "create_customer")" "message=Invalid API Key provided" \
        "validate-stripe should include the Stripe error message in failure details"
    assert_contains "$(json_step_detail "$output" "create_customer")" "log=https://dashboard.stripe.com/test/workbench/logs?object=req_mock_create_customer" \
        "validate-stripe should include the Stripe request log URL in failure details"

    rm -rf "$mock_dir"
}

test_validate_stripe_test_clock_success_drives_lifecycle() {
    local mock_dir response_file call_log output
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    call_log="$mock_dir/curl_args.log"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":200,"body":"{\"id\":\"clock_mock_test_clock\",\"status\":\"ready\"}","headers":{"Request-Id":"req_create_test_clock"}},
  {"status":200,"body":"{\"id\":\"cus_mock_test_clock_customer\"}","headers":{"Request-Id":"req_create_customer"}},
  {"status":200,"body":"{\"id\":\"clock_mock_test_clock\",\"status\":\"advancing\"}","headers":{"Request-Id":"req_advance_test_clock"}},
  {"status":200,"body":"{\"id\":\"clock_mock_test_clock\",\"status\":\"ready\"}","headers":{"Request-Id":"req_get_test_clock_ready"}},
  {"status":200,"body":"{\"id\":\"clock_mock_test_clock\",\"deleted\":true}","headers":{"Request-Id":"req_delete_test_clock"}}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    output="$(STRIPE_SECRET_KEY='sk_test_clock_mock' STRIPE_TEST_RESPONSE_FILE="$response_file" STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" --test-clock)"

    assert_valid_json "$output" "validate-stripe --test-clock success output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "validate-stripe --test-clock success flow should report passed=true"
    assert_contains "$output" "create_test_clock" "validate-stripe --test-clock output should include create_test_clock step"
    assert_contains "$output" "advance_test_clock" "validate-stripe --test-clock output should include advance_test_clock step"
    assert_contains "$output" "delete_test_clock" "validate-stripe --test-clock output should include delete_test_clock step"
    assert_contains "$(cat "$call_log")" "https://api.stripe.com/v1/test_helpers/test_clocks" \
        "validate-stripe --test-clock should POST to /v1/test_helpers/test_clocks"
    assert_contains "$(cat "$call_log")" "/v1/test_helpers/test_clocks/clock_mock_test_clock/advance" \
        "validate-stripe --test-clock should advance the created test clock"
    assert_contains "$(cat "$call_log")" "DELETE" \
        "validate-stripe --test-clock should issue a DELETE on cleanup"
    assert_contains "$(cat "$call_log")" "https://api.stripe.com/v1/test_helpers/test_clocks/clock_mock_test_clock" \
        "validate-stripe --test-clock DELETE should target the created clock id"
    assert_not_contains "$(cat "$call_log")" "pm_card_visa" \
        "validate-stripe --test-clock should not touch the test-mode invoice lifecycle pm_card_visa fixture"
    assert_not_contains "$(cat "$call_log")" "/v1/invoices/" \
        "validate-stripe --test-clock should not pay invoices in this lifecycle"

    rm -rf "$mock_dir"
}

test_validate_stripe_test_clock_waits_until_advance_ready_before_cleanup() {
    local mock_dir response_file call_log output
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    call_log="$mock_dir/curl_args.log"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":200,"body":"{\"id\":\"clock_mock_async_ready\",\"status\":\"ready\"}","headers":{"Request-Id":"req_create_test_clock"}},
  {"status":200,"body":"{\"id\":\"cus_mock_async_ready_customer\"}","headers":{"Request-Id":"req_create_customer"}},
  {"status":200,"body":"{\"id\":\"clock_mock_async_ready\",\"status\":\"advancing\"}","headers":{"Request-Id":"req_advance_test_clock"}},
  {"status":200,"body":"{\"id\":\"clock_mock_async_ready\",\"status\":\"ready\"}","headers":{"Request-Id":"req_get_test_clock_ready"}},
  {"status":200,"body":"{\"id\":\"clock_mock_async_ready\",\"deleted\":true}","headers":{"Request-Id":"req_delete_test_clock"}}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    output="$(STRIPE_SECRET_KEY='sk_test_clock_async_ready' STRIPE_TEST_RESPONSE_FILE="$response_file" STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" --test-clock)"

    assert_valid_json "$output" "validate-stripe --test-clock async advance output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "validate-stripe --test-clock async advance flow should report passed=true only after readiness"
    assert_contains "$output" "wait_test_clock_ready" \
        "validate-stripe --test-clock async advance output should include readiness wait evidence"
    assert_contains "$(cat "$call_log")" "GET" \
        "validate-stripe --test-clock should retrieve the test clock after an advancing response"
    assert_contains "$(cat "$call_log")" "DELETE" \
        "validate-stripe --test-clock should still delete the test clock after readiness"

    rm -rf "$mock_dir"
}

test_validate_stripe_test_clock_failure_after_create_emits_cleanup_step() {
    local mock_dir response_file call_log output exit_code
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    call_log="$mock_dir/curl_args.log"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":200,"body":"{\"id\":\"clock_mock_cleanup_after_failure\",\"status\":\"ready\"}","headers":{"Request-Id":"req_create_test_clock"}},
  {"status":402,"body":"{\"error\":{\"type\":\"card_error\",\"message\":\"mock customer failure\"}}","headers":{"Request-Id":"req_create_customer_failure"}},
  {"status":200,"body":"{\"id\":\"clock_mock_cleanup_after_failure\",\"deleted\":true}","headers":{"Request-Id":"req_delete_test_clock"}}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    output="$(STRIPE_SECRET_KEY='sk_test_clock_failure_cleanup' STRIPE_TEST_RESPONSE_FILE="$response_file" STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" --test-clock 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe --test-clock should fail when customer creation fails"
    assert_valid_json "$output" "validate-stripe --test-clock post-create failure output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe --test-clock post-create failure JSON should report passed=false"
    assert_contains "$output" "create_test_clock_customer" \
        "validate-stripe --test-clock post-create failure output should include the failing customer step"
    assert_contains "$output" "delete_test_clock" \
        "validate-stripe --test-clock post-create failure output should include cleanup evidence"
    assert_contains "$(cat "$call_log")" "DELETE" \
        "validate-stripe --test-clock post-create failure should issue a DELETE on cleanup"
    assert_contains "$(cat "$call_log")" "https://api.stripe.com/v1/test_helpers/test_clocks/clock_mock_cleanup_after_failure" \
        "validate-stripe --test-clock post-create failure cleanup should target the created clock id"

    rm -rf "$mock_dir"
}

test_validate_stripe_test_clock_rejects_live_canonical_key_before_api_calls() {
    local mock_dir call_log output exit_code
    mock_dir="$(mktemp -d)"
    call_log="$mock_dir/curl_called.log"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo "called" >> "$STRIPE_TEST_CALL_LOG"
echo '{"id":"cus_mock"}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    output="$(STRIPE_SECRET_KEY='sk_live_test_clock_reject' STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" --test-clock 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe --test-clock should reject sk_live_ canonical key before API calls"
    assert_valid_json "$output" "validate-stripe --test-clock sk_live rejection output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe --test-clock sk_live rejection JSON should report passed=false"
    assert_contains "$output" "require_test_mode_stripe_secret_key" "validate-stripe --test-clock should preserve test-mode key guard step naming"
    assert_contains "$(json_step_detail "$output" "require_test_mode_stripe_secret_key")" "sk_test_" \
        "validate-stripe --test-clock sk_live detail should require sk_test_ prefix"
    if [ -f "$call_log" ]; then
        fail "validate-stripe --test-clock should not call curl when canonical key is sk_live_"
    else
        pass "validate-stripe --test-clock should not call curl when canonical key is sk_live_"
    fi

    rm -rf "$mock_dir"
}

test_validate_stripe_test_clock_rejects_restricted_live_canonical_key_before_api_calls() {
    local mock_dir call_log output exit_code
    mock_dir="$(mktemp -d)"
    call_log="$mock_dir/curl_called.log"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo "called" >> "$STRIPE_TEST_CALL_LOG"
echo '{"id":"cus_mock"}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    output="$(STRIPE_SECRET_KEY='rk_live_test_clock_reject' STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" --test-clock 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe --test-clock should reject rk_live_ canonical key before API calls"
    assert_valid_json "$output" "validate-stripe --test-clock rk_live rejection output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe --test-clock rk_live rejection JSON should report passed=false"
    assert_contains "$output" "require_test_mode_stripe_secret_key" "validate-stripe --test-clock should preserve test-mode key guard step naming for rk_live"
    assert_contains "$(json_step_detail "$output" "require_test_mode_stripe_secret_key")" "rk_test_" \
        "validate-stripe --test-clock rk_live detail should reference rk_test_ allowance text"
    if [ -f "$call_log" ]; then
        fail "validate-stripe --test-clock should not call curl when canonical key is rk_live_"
    else
        pass "validate-stripe --test-clock should not call curl when canonical key is rk_live_"
    fi

    rm -rf "$mock_dir"
}

test_validate_stripe_test_clock_and_live_cutover_are_mutually_exclusive() {
    local mock_dir call_log output exit_code
    mock_dir="$(mktemp -d)"
    call_log="$mock_dir/curl_called.log"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo "called" >> "$STRIPE_TEST_CALL_LOG"
echo '{"id":"cus_mock"}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    output="$(STRIPE_SECRET_KEY='sk_test_mutex_check' STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" --test-clock --live-cutover 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "validate-stripe should refuse --test-clock and --live-cutover together"
    assert_valid_json "$output" "validate-stripe --test-clock+--live-cutover output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe mutex rejection JSON should report passed=false"
    if [ -f "$call_log" ]; then
        fail "validate-stripe should not call curl when --test-clock and --live-cutover are combined"
    else
        pass "validate-stripe should reject --test-clock + --live-cutover before any curl call"
    fi

    rm -rf "$mock_dir"
}

test_secret_rotation_runbook_avoids_inline_secret_cli_examples() {
    local runbook
    runbook="$(cat "$ROTATION_RUNBOOK_FILE")"

    assert_contains "$runbook" "Do not paste literal secret values into the command line" \
        "Stripe rotation runbook should warn against inline CLI secrets"
    assert_not_contains "$runbook" "STRIPE_SECRET_KEY=<sk_test_...|rk_test_...> STRIPE_WEBHOOK_SECRET=whsec_... bash scripts/validate-stripe.sh" \
        "Stripe rotation runbook should not teach inline secret injection on the command line"
}

echo "=== validate-stripe.sh tests ==="
test_validate_stripe_fails_when_key_unset
test_validate_stripe_fails_gracefully_with_invalid_key
test_validate_stripe_alias_fallback_when_canonical_missing
test_validate_stripe_accepts_restricted_canonical_key
test_validate_stripe_accepts_restricted_alias_key
test_validate_stripe_rejects_live_canonical_key_before_api_calls
test_validate_stripe_rejects_live_alias_key_before_api_calls
test_validate_stripe_rejects_restricted_live_canonical_key_before_api_calls
test_validate_stripe_rejects_restricted_live_alias_key_before_api_calls
test_validate_stripe_default_mode_keeps_test_mode_step_names
test_validate_stripe_live_cutover_requires_control
test_validate_stripe_live_cutover_allows_live_keys_with_control
test_validate_stripe_live_cutover_rejects_test_keys
test_validate_stripe_live_cutover_avoids_test_payment_method_token
test_validate_stripe_uses_attached_payment_method_id_for_default
test_validate_stripe_surfaces_stripe_error_context
test_validate_stripe_test_clock_success_drives_lifecycle
test_validate_stripe_test_clock_waits_until_advance_ready_before_cleanup
test_validate_stripe_test_clock_failure_after_create_emits_cleanup_step
test_validate_stripe_test_clock_rejects_live_canonical_key_before_api_calls
test_validate_stripe_test_clock_rejects_restricted_live_canonical_key_before_api_calls
test_validate_stripe_test_clock_and_live_cutover_are_mutually_exclusive
test_secret_rotation_runbook_avoids_inline_secret_cli_examples

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
