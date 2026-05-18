#!/usr/bin/env bash
# Contract test for scripts/launch/capture_upgrade_trust_ratchet_evidence.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/launch/capture_upgrade_trust_ratchet_evidence.sh"

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

assert_contains() {
    local actual="$1"
    local expected_substring="$2"
    local message="$3"
    if [[ "$actual" == *"$expected_substring"* ]]; then
        pass "$message"
    else
        fail "$message (missing substring '$expected_substring')"
    fi
}

assert_not_contains() {
    local actual="$1"
    local unexpected_substring="$2"
    local message="$3"
    if [[ "$actual" == *"$unexpected_substring"* ]]; then
        fail "$message (unexpected substring '$unexpected_substring')"
    else
        pass "$message"
    fi
}

run_verify_contract_helper() {
    local label="$1"
    local expected_http="$2"
    local actual_http="$3"
    local response_body="$4"
    local post_status="$5"
    local trimmed_script
    trimmed_script="$(mktemp "${TMPDIR:-/tmp}/fjcloud-upgrade-trust-ratchet-helper.XXXXXX")"
    sed '/^log "Evidence capture starting\./,$d' "$TARGET_SCRIPT" > "$trimmed_script"
    local exit_code=0
    bash -lc '
        export API_URL="https://api.test.invalid"
        export ADMIN_KEY="test-admin-key"
        export STRIPE_SECRET_KEY="sk_test_contract"
        source "$1"
        verify_contract_expectations "$2" "$3" "$4" "$5" "$6"
    ' _ "$trimmed_script" "$label" "$expected_http" "$actual_http" "$response_body" "$post_status" \
        >/dev/null 2>&1 || exit_code=$?
    rm -f "$trimmed_script"
    return "$exit_code"
}

test_payment_methods_are_parameterized_not_hardcoded() {
    local script_content
    script_content="$(cat "$TARGET_SCRIPT")"

    assert_contains "$script_content" "UPGRADE_PM_SUCCESS" "script should define success payment method env owner"
    assert_contains "$script_content" "UPGRADE_PM_DECLINED" "script should define declined payment method env owner"
    assert_contains "$script_content" "UPGRADE_PM_REQUIRES_ACTION" "script should define requires-action payment method env owner"

    assert_not_contains "$script_content" 'exercise_contract "success_paid" "pm_card_visa" "200"' "success contract should not hardcode pm_card_visa"
    assert_not_contains "$script_content" 'exercise_contract "declined_402" "pm_card_chargeDeclined" "402"' "declined contract should not hardcode pm_card_chargeDeclined"
    assert_not_contains "$script_content" 'exercise_contract "requires_action_402" "pm_card_authenticationRequired" "402"' "requires_action contract should not hardcode pm_card_authenticationRequired"
}

test_stripe_attach_failure_is_fail_closed_with_owner_message() {
    local script_content
    script_content="$(cat "$TARGET_SCRIPT")"

    assert_contains "$script_content" "stripe_request_json()" "script should centralize Stripe HTTP+JSON parsing in a single helper"
    assert_contains "$script_content" "ERROR: stripe attach failed for payment method" "attach failures should produce an explicit owner-scoped error"
    assert_contains "$script_content" "stripe default payment method update failed" "default-PM update failures should produce an explicit owner-scoped error"
    assert_not_contains "$script_content" "json.decoder.JSONDecodeError" "script should not rely on uncaught Python JSON decode traces for Stripe error handling"
}

test_contract_verifier_fails_closed_on_http_mismatch() {
    if run_verify_contract_helper \
        "success_paid" \
        "200" \
        "402" \
        '{"error":"payment_required","code":"card_declined"}' \
        '{"upgrade_ready": true}'; then
        fail "verify_contract_expectations should fail closed when the HTTP status mismatches the contract"
    fi
    pass "verify_contract_expectations fails closed on HTTP mismatch"
}

test_contract_verifier_accepts_decline_retry_contract() {
    if ! run_verify_contract_helper \
        "declined_402" \
        "402" \
        "402" \
        '{"error":"payment_required","code":"card_declined"}' \
        '{"upgrade_ready": true}'; then
        fail "declined retry contract should verify successfully"
        return
    fi
    pass "verify_contract_expectations accepts the declined retry contract"
}

echo "=== capture_upgrade_trust_ratchet_evidence contract tests ==="
test_payment_methods_are_parameterized_not_hardcoded
test_stripe_attach_failure_is_fail_closed_with_owner_message
test_contract_verifier_fails_closed_on_http_mismatch
test_contract_verifier_accepts_decline_retry_contract
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
