#!/usr/bin/env bash
# Tests for scripts/validate-stripe.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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

echo "=== validate-stripe.sh tests ==="
test_validate_stripe_fails_when_key_unset
test_validate_stripe_fails_gracefully_with_invalid_key
test_validate_stripe_alias_fallback_when_canonical_missing
test_validate_stripe_rejects_live_canonical_key_before_api_calls
test_validate_stripe_rejects_live_alias_key_before_api_calls
test_validate_stripe_uses_attached_payment_method_id_for_default
test_validate_stripe_surfaces_stripe_error_context

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
