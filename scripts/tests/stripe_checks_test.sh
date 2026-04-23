#!/usr/bin/env bash
# Tests for scripts/lib/stripe_checks.sh: Stripe validation check functions.
# Validates script logic without requiring real Stripe API keys — uses
# controlled env vars in subshells and mock curl responses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$msg (expected='$expected' actual='$actual')"
    else
        pass "$msg"
    fi
}

assert_contains() {
    local actual="$1" expected_substr="$2" msg="$3"
    if [[ "$actual" != *"$expected_substr"* ]]; then
        fail "$msg (expected substring '$expected_substr' in '$actual')"
    else
        pass "$msg"
    fi
}

assert_not_contains() {
    local actual="$1" unexpected_substr="$2" msg="$3"
    if [[ "$actual" == *"$unexpected_substr"* ]]; then
        fail "$msg (unexpected substring '$unexpected_substr' found in '$actual')"
    else
        pass "$msg"
    fi
}

# ============================================================================
# stripe_webhook_forward_to tests
# ============================================================================

test_stripe_webhook_forward_to_defaults_to_local_api() {
    local output
    output="$(bash -c "
        unset STRIPE_WEBHOOK_FORWARD_TO API_URL API_PORT LISTEN_ADDR
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        stripe_webhook_forward_to
    ")"

    assert_eq "$output" "http://localhost:3001/webhooks/stripe" \
        "stripe_webhook_forward_to should default to the local API port"
}

test_stripe_webhook_forward_to_uses_explicit_override() {
    local output
    output="$(STRIPE_WEBHOOK_FORWARD_TO='https://api.example.test/webhooks/stripe' bash -c "
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        stripe_webhook_forward_to
    ")"

    assert_eq "$output" "https://api.example.test/webhooks/stripe" \
        "stripe_webhook_forward_to should honor STRIPE_WEBHOOK_FORWARD_TO"
}

test_stripe_webhook_forward_to_uses_api_url_when_present() {
    local output
    output="$(API_URL='http://localhost:3099/' bash -c "
        unset STRIPE_WEBHOOK_FORWARD_TO API_PORT LISTEN_ADDR
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        stripe_webhook_forward_to
    ")"

    assert_eq "$output" "http://localhost:3099/webhooks/stripe" \
        "stripe_webhook_forward_to should derive the path from API_URL"
}

test_stripe_webhook_forward_to_uses_listen_addr_when_present() {
    local output
    output="$(LISTEN_ADDR='0.0.0.0:3099' bash -c "
        unset STRIPE_WEBHOOK_FORWARD_TO API_URL API_PORT
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        stripe_webhook_forward_to
    ")"

    assert_eq "$output" "http://localhost:3099/webhooks/stripe" \
        "stripe_webhook_forward_to should map wildcard LISTEN_ADDR hosts to localhost"
}

test_stripe_webhook_forward_to_uses_api_port_when_present() {
    local output
    output="$(API_PORT='3099' bash -c "
        unset STRIPE_WEBHOOK_FORWARD_TO API_URL LISTEN_ADDR
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        stripe_webhook_forward_to
    ")"

    assert_eq "$output" "http://localhost:3099/webhooks/stripe" \
        "stripe_webhook_forward_to should fall back to API_PORT"
}

# ============================================================================
# check_stripe_key_present tests
# ============================================================================

test_check_stripe_key_present_fails_when_unset() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        unset STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_present
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_stripe_key_present should fail when key is unset (gate on)"
    assert_contains "$output" "STRIPE_SECRET_KEY" "output should mention canonical Stripe key env var"
}

test_check_stripe_key_present_emits_reason_code_on_fail() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        unset STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_present
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_stripe_key_present should fail when key is unset (gate on)"
    assert_contains "$output" "REASON: stripe_key_unset" "failure output should include stripe_key_unset reason code"
}

test_check_stripe_key_present_fails_when_wrong_prefix() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="rk_live_bad" bash -c "
        unset STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_present
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_stripe_key_present should fail when key has wrong prefix (gate on)"
    assert_contains "$output" "STRIPE_SECRET_KEY" "wrong-prefix output should reference canonical env var"
    assert_contains "$output" "sk_test_" "output should mention expected prefix"
}

test_check_stripe_key_present_emits_reason_code_wrong_prefix() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="rk_live_bad" bash -c "
        unset STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_present
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_stripe_key_present should fail when key has wrong prefix (gate on)"
    assert_contains "$output" "REASON: stripe_key_bad_prefix" "failure output should include stripe_key_bad_prefix reason code"
}

test_check_stripe_key_present_skips_when_unset_gate_off() {
    local output exit_code
    output="$(unset BACKEND_LIVE_GATE; bash -c "
        unset BACKEND_LIVE_GATE
        unset STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_present
        echo 'CONTINUED'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_stripe_key_present should skip (exit 0) when gate is off"
    assert_contains "$output" "[skip]" "output should contain [skip] marker"
    assert_contains "$output" "CONTINUED" "execution should continue after skip"
}

test_check_stripe_key_present_passes_with_valid_key() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="sk_test_abc123" bash -c "
        unset STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_present
        echo 'OK'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_stripe_key_present should pass with valid key"
    assert_contains "$output" "OK" "execution should continue after passing check"
}

test_check_stripe_key_present_falls_back_to_alias_when_canonical_missing() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_TEST_SECRET_KEY="sk_test_alias_only" bash -c "
        unset STRIPE_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_present
        echo 'ALIAS_OK'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_stripe_key_present should accept STRIPE_TEST_SECRET_KEY only when canonical is absent"
    assert_contains "$output" "ALIAS_OK" "alias fallback should allow execution to continue"
}

test_check_stripe_key_present_prefers_canonical_over_alias() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="sk_test_canonical" STRIPE_TEST_SECRET_KEY="sk_live_alias_should_not_win" bash -c "
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_present
        echo 'CANONICAL_WINS'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_stripe_key_present should prioritize canonical STRIPE_SECRET_KEY when both keys are set"
    assert_contains "$output" "CANONICAL_WINS" "canonical key should be used when both key vars are present"
}

test_check_stripe_key_present_fails_when_canonical_empty_even_with_alias() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY='' STRIPE_TEST_SECRET_KEY='sk_test_alias_should_not_apply' bash -c "
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_present
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" \
        "check_stripe_key_present should fail when canonical STRIPE_SECRET_KEY is explicitly empty"
    assert_contains "$output" "REASON: stripe_key_unset" \
        "empty canonical key should be treated as missing instead of falling back to alias"
}

test_check_stripe_key_present_rejects_live_key_with_canonical_text() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="sk_live_stage2_red" bash -c "
        unset STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_present
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_stripe_key_present should reject live Stripe keys"
    assert_contains "$output" "sk_live_" "live-key rejection should mention live-mode key prefix"
    assert_contains "$output" "STRIPE_SECRET_KEY" "live-key rejection should point operators to canonical key contract"
}

# ============================================================================
# check_stripe_key_live tests
# ============================================================================

test_check_stripe_key_live_fails_on_401() {
    # Create a mock curl that simulates -w "\n%{http_code}" output
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
# Mock curl: return 401 Unauthorized with -w http_code format
echo '{"error":{"type":"authentication_error","message":"Invalid API Key provided"}}'
echo "401"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="sk_test_invalid_key" PATH="$mock_dir:$PATH" bash -c "
        unset STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_live
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "check_stripe_key_live should fail on authentication error (gate on)"
    assert_contains "$output" "Stripe" "output should mention Stripe"
}

test_check_stripe_key_live_emits_reason_code_on_auth_fail() {
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
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="sk_test_invalid_key" PATH="$mock_dir:$PATH" bash -c "
        unset STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_live
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "check_stripe_key_live should fail on authentication error (gate on)"
    assert_contains "$output" "REASON: stripe_auth_failed" "failure output should include stripe_auth_failed reason code"
}

test_check_stripe_key_live_passes_on_success() {
    # Create a mock curl that simulates -w "\n%{http_code}" output
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
# Mock curl: return a valid Stripe balance response with 200 status
echo '{"object":"balance","available":[{"amount":0,"currency":"usd"}]}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="sk_test_valid123" PATH="$mock_dir:$PATH" bash -c "
        unset STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_live
        echo 'LIVE_OK'
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "check_stripe_key_live should pass with valid API response"
    assert_contains "$output" "LIVE_OK" "execution should continue after live check passes"
}

test_check_stripe_key_live_skips_when_gate_off() {
    # Mock curl that returns auth error — but gate is off so it should skip
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"error":{"type":"authentication_error","message":"bad key"}}'
echo "401"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(unset BACKEND_LIVE_GATE; STRIPE_SECRET_KEY="sk_test_invalid" PATH="$mock_dir:$PATH" bash -c "
        unset BACKEND_LIVE_GATE
        unset STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_live
        echo 'SKIPPED_OK'
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "check_stripe_key_live should skip when gate is off"
    assert_contains "$output" "SKIPPED_OK" "execution should continue after skip"
}

test_check_stripe_key_live_emits_timeout_reason() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
exit 28
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="sk_test_timeout" PATH="$mock_dir:$PATH" bash -c "
        unset STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_live
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "124" \
        "check_stripe_key_live should return 124 when curl times out"
    assert_contains "$output" "REASON: stripe_api_timeout" \
        "timeout should emit REASON: stripe_api_timeout"
}

test_stripe_api_timeout_produces_specific_reason() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo "curl: (28) Operation timed out after 15000 milliseconds with 0 bytes received" >&2
exit 28
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="sk_test_timeout" PATH="$mock_dir:$PATH" bash -c "
        unset STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_live
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "124" \
        "check_stripe_key_live should return 124 when curl exits 28 timeout"
    assert_contains "$output" "REASON: stripe_api_timeout" \
        "timeout failure should include stripe_api_timeout reason code"
}

test_stripe_api_connect_timeout_produces_specific_reason() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
sleep 0.2
echo "curl: (28) Failed to connect to api.stripe.com port 443 after 5000 ms: Timeout was reached" >&2
exit 28
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="sk_test_connect_timeout" PATH="$mock_dir:$PATH" bash -c "
        unset STRIPE_TEST_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_live
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "124" \
        "check_stripe_key_live should return 124 when curl connect phase times out"
    assert_contains "$output" "REASON: stripe_api_timeout" \
        "connect timeout should include stripe_api_timeout reason code"
}

test_check_stripe_key_live_falls_back_to_alias_when_canonical_missing() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"object":"balance","available":[{"amount":0,"currency":"usd"}]}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_TEST_SECRET_KEY="sk_test_alias_live" PATH="$mock_dir:$PATH" bash -c "
        unset STRIPE_SECRET_KEY
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_live
        echo 'ALIAS_LIVE_OK'
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "check_stripe_key_live should allow STRIPE_TEST_SECRET_KEY fallback when canonical is absent"
    assert_contains "$output" "ALIAS_LIVE_OK" "alias fallback should allow live check to complete"
}

test_check_stripe_key_live_prefers_canonical_over_alias() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
expected="sk_test_canonical_live"
auth=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-u" ] && [ "$#" -ge 2 ]; then
        auth="$2"
        shift 2
        continue
    fi
    shift
done
if [ "$auth" != "${expected}:" ]; then
    echo '{"error":{"type":"authentication_error","message":"unexpected key"}}'
    echo "401"
    exit 0
fi
echo '{"object":"balance","available":[{"amount":0,"currency":"usd"}]}'
echo "200"
exit 0
MOCK
    chmod +x "$mock_dir/curl"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_SECRET_KEY="sk_test_canonical_live" STRIPE_TEST_SECRET_KEY="sk_test_alias_should_not_be_used" PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_key_live
        echo 'CANONICAL_LIVE_WINS'
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "check_stripe_key_live should use canonical key when both canonical and alias are set"
    assert_contains "$output" "CANONICAL_LIVE_WINS" "live check should pass when canonical key is used"
}

# ============================================================================
# check_stripe_webhook_secret_present tests
# ============================================================================

test_check_stripe_webhook_secret_present_fails_when_unset() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        unset STRIPE_WEBHOOK_SECRET
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_webhook_secret_present
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_stripe_webhook_secret_present should fail when secret is unset (gate on)"
    assert_contains "$output" "STRIPE_WEBHOOK_SECRET" "output should mention the env var"
}

test_check_stripe_webhook_secret_present_emits_reason_code_on_fail() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        unset STRIPE_WEBHOOK_SECRET
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_webhook_secret_present
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_stripe_webhook_secret_present should fail when secret is unset (gate on)"
    assert_contains "$output" "REASON: stripe_webhook_secret_unset" "failure output should include stripe_webhook_secret_unset reason code"
}

test_check_stripe_webhook_secret_present_fails_when_wrong_prefix() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_WEBHOOK_SECRET="bad_prefix_123" bash -c "
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_webhook_secret_present
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_stripe_webhook_secret_present should fail with wrong prefix (gate on)"
    assert_contains "$output" "whsec_" "output should mention expected prefix"
}

test_check_stripe_webhook_secret_present_skips_when_gate_off() {
    local output exit_code
    output="$(unset BACKEND_LIVE_GATE; bash -c "
        unset BACKEND_LIVE_GATE
        unset STRIPE_WEBHOOK_SECRET
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_webhook_secret_present
        echo 'CONTINUED'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_stripe_webhook_secret_present should skip when gate off"
    assert_contains "$output" "[skip]" "output should contain skip marker"
}

test_check_stripe_webhook_secret_present_passes_with_valid_secret() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 STRIPE_WEBHOOK_SECRET="whsec_test_abc123" bash -c "
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_webhook_secret_present
        echo 'OK'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_stripe_webhook_secret_present should pass with valid secret"
    assert_contains "$output" "OK" "execution should continue"
}

# ============================================================================
# check_stripe_webhook_forwarding tests
# ============================================================================

test_check_stripe_webhook_forwarding_fails_when_no_process() {
    # Mock pgrep that finds nothing
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/pgrep" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$mock_dir/pgrep"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_webhook_forwarding
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "check_stripe_webhook_forwarding should fail when no stripe listen process (gate on)"
    assert_contains "$output" "stripe listen" "output should mention stripe listen"
}

test_check_stripe_webhook_forwarding_emits_reason_code_on_fail() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/pgrep" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$mock_dir/pgrep"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_webhook_forwarding
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "check_stripe_webhook_forwarding should fail when no stripe listen process (gate on)"
    assert_contains "$output" "REASON: stripe_listen_not_running" "failure output should include stripe_listen_not_running reason code"
}

test_check_stripe_webhook_forwarding_passes_when_process_running() {
    # Mock pgrep that finds a process
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/pgrep" <<'MOCK'
#!/usr/bin/env bash
# Simulate finding a "stripe listen" process
if [[ "$*" == *"stripe"* ]]; then
    echo "12345"
    exit 0
fi
exit 1
MOCK
    chmod +x "$mock_dir/pgrep"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 PATH="$mock_dir:$PATH" bash -c "
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_webhook_forwarding
        echo 'FORWARDING_OK'
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "check_stripe_webhook_forwarding should pass when stripe listen is running"
    assert_contains "$output" "FORWARDING_OK" "execution should continue"
}

test_check_stripe_webhook_forwarding_skips_when_gate_off() {
    # Mock pgrep that fails — but gate is off
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/pgrep" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$mock_dir/pgrep"

    local output exit_code
    output="$(unset BACKEND_LIVE_GATE; PATH="$mock_dir:$PATH" bash -c "
        unset BACKEND_LIVE_GATE
        source '$REPO_ROOT/scripts/lib/stripe_checks.sh'
        check_stripe_webhook_forwarding
        echo 'SKIPPED_OK'
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "check_stripe_webhook_forwarding should skip when gate off"
    assert_contains "$output" "SKIPPED_OK" "execution should continue after skip"
}

# ============================================================================
# Run tests
# ============================================================================

echo "=== stripe_checks.sh tests ==="
echo ""
echo "--- stripe_webhook_forward_to ---"
test_stripe_webhook_forward_to_defaults_to_local_api
test_stripe_webhook_forward_to_uses_explicit_override
test_stripe_webhook_forward_to_uses_api_url_when_present
test_stripe_webhook_forward_to_uses_listen_addr_when_present
test_stripe_webhook_forward_to_uses_api_port_when_present
echo ""
echo "--- check_stripe_key_present ---"
test_check_stripe_key_present_fails_when_unset
test_check_stripe_key_present_emits_reason_code_on_fail
test_check_stripe_key_present_fails_when_wrong_prefix
test_check_stripe_key_present_emits_reason_code_wrong_prefix
test_check_stripe_key_present_skips_when_unset_gate_off
test_check_stripe_key_present_passes_with_valid_key
test_check_stripe_key_present_falls_back_to_alias_when_canonical_missing
test_check_stripe_key_present_prefers_canonical_over_alias
test_check_stripe_key_present_fails_when_canonical_empty_even_with_alias
test_check_stripe_key_present_rejects_live_key_with_canonical_text
echo ""
echo "--- check_stripe_key_live ---"
test_check_stripe_key_live_fails_on_401
test_check_stripe_key_live_emits_reason_code_on_auth_fail
test_check_stripe_key_live_passes_on_success
test_check_stripe_key_live_skips_when_gate_off
test_check_stripe_key_live_emits_timeout_reason
test_stripe_api_timeout_produces_specific_reason
test_stripe_api_connect_timeout_produces_specific_reason
test_check_stripe_key_live_falls_back_to_alias_when_canonical_missing
test_check_stripe_key_live_prefers_canonical_over_alias
echo ""
echo "--- check_stripe_webhook_secret_present ---"
test_check_stripe_webhook_secret_present_fails_when_unset
test_check_stripe_webhook_secret_present_emits_reason_code_on_fail
test_check_stripe_webhook_secret_present_fails_when_wrong_prefix
test_check_stripe_webhook_secret_present_skips_when_gate_off
test_check_stripe_webhook_secret_present_passes_with_valid_secret
echo ""
echo "--- check_stripe_webhook_forwarding ---"
test_check_stripe_webhook_forwarding_fails_when_no_process
test_check_stripe_webhook_forwarding_emits_reason_code_on_fail
test_check_stripe_webhook_forwarding_passes_when_process_running
test_check_stripe_webhook_forwarding_skips_when_gate_off
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
