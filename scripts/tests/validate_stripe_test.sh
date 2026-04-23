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
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"error":{"type":"authentication_error","message":"Invalid API Key provided"}}'
echo "401"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(STRIPE_SECRET_KEY='sk_test_invalid' PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-stripe should fail with invalid Stripe key"
    assert_valid_json "$output" "validate-stripe invalid-key output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "validate-stripe invalid-key JSON should report passed=false"
    assert_contains "$output" "create_customer" "validate-stripe invalid-key output should include create_customer step"
    assert_contains "$(json_step_detail "$output" "create_customer")" "HTTP 401" \
        "validate-stripe invalid-key machine-readable detail should include HTTP 401"
}

test_validate_stripe_alias_fallback_when_canonical_missing() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"error":{"type":"authentication_error","message":"Invalid API Key provided"}}'
echo "401"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(env -u STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY='sk_test_alias_invalid' PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate-stripe.sh" 2>&1)" || exit_code=$?

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

echo "=== validate-stripe.sh tests ==="
test_validate_stripe_fails_when_key_unset
test_validate_stripe_fails_gracefully_with_invalid_key
test_validate_stripe_alias_fallback_when_canonical_missing
test_validate_stripe_rejects_live_canonical_key_before_api_calls
test_validate_stripe_rejects_live_alias_key_before_api_calls

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
