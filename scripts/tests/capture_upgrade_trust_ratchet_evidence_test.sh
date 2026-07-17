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

run_payment_method_resolution_helper() {
    local stripe_secret_key="$1"
    local lifecycle_probe_pm_id="$2"
    local trimmed_script
    trimmed_script="$(mktemp "${TMPDIR:-/tmp}/fjcloud-upgrade-trust-ratchet-init.XXXXXX")"
    sed '/^log "Evidence capture starting\./,$d' "$TARGET_SCRIPT" > "$trimmed_script"
    local output
    local exit_code=0
    output="$(
        bash -lc '
            export API_URL="https://api.test.invalid"
            export ADMIN_KEY="test-admin-key"
            export STRIPE_SECRET_KEY="$2"
            export LIFECYCLE_PROBE_PM_ID="$3"
            unset UPGRADE_PM_SUCCESS UPGRADE_PM_DECLINED UPGRADE_PM_REQUIRES_ACTION
            unset LIFECYCLE_PROBE_PM_DECLINED_ID LIFECYCLE_PROBE_PM_REQUIRES_ACTION_ID
            source "$1"
            printf "%s|%s|%s\n" \
                "$UPGRADE_PM_SUCCESS" \
                "$UPGRADE_PM_DECLINED" \
                "$UPGRADE_PM_REQUIRES_ACTION"
        ' _ "$trimmed_script" "$stripe_secret_key" "$lifecycle_probe_pm_id" 2>/dev/null
    )" || exit_code=$?
    rm -f "$trimmed_script"
    if [ "$exit_code" -ne 0 ]; then
        return "$exit_code"
    fi
    echo "$output"
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

test_setup_artifact_omits_raw_payment_method_value() {
    local script_content
    script_content="$(cat "$TARGET_SCRIPT")"

    assert_contains "$script_content" '\"customer_id\": \"${customer_id}\"' "setup artifact should preserve customer_id audit identifier"
    assert_contains "$script_content" '\"stripe_customer_id\": \"${stripe_customer_id}\"' "setup artifact should preserve stripe_customer_id audit identifier"
    assert_not_contains "$script_content" '\"pm_token\": \"${pm_token}\"' "setup artifact must not persist raw payment method tokens"
    assert_not_contains "$script_content" '\"payment_method\": \"${pm_token}\"' "setup artifact must not alias raw payment method tokens under payment_method"
}

test_upgrade_status_probe_has_404_fallback_contract() {
    local script_content
    script_content="$(cat "$TARGET_SCRIPT")"

    assert_contains "$script_content" "tenant_get_with_status()" "script should provide GET-with-status helper for fallback-aware probes"
    assert_contains "$script_content" "falling back to /account + /billing/payment-methods contract" "script should log explicit fallback owner context on upgrade-status 404"
    assert_contains "$script_content" "/billing/payment-methods" "fallback should fetch billing payment methods to preserve upgrade_ready semantics"
    assert_contains "$script_content" "fetch_upgrade_status_json_with_fallback()" "script should centralize upgrade-status fallback logic in one owner helper"
    assert_contains "$script_content" "cat > \"\${EVIDENCE_DIR}/SUMMARY.md\" <<'SUMMARYEOF'" \
        "SUMMARY.md heredoc must be quoted so markdown backticks are not executed as shell commands"
}

test_test_mode_ignores_lifecycle_probe_payment_method_aliases() {
    local resolved
    resolved="$(run_payment_method_resolution_helper "sk_test_contract" "pm_not_from_staging_account")" || {
        fail "test-mode payment-method resolution helper should initialize successfully"
        return
    }

    local resolved_success resolved_declined resolved_requires_action
    resolved_success="$(echo "$resolved" | cut -d'|' -f1)"
    resolved_declined="$(echo "$resolved" | cut -d'|' -f2)"
    resolved_requires_action="$(echo "$resolved" | cut -d'|' -f3)"

    if [ "$resolved_success" != "pm_card_visa" ]; then
        fail "test-mode success payment method should default to pm_card_visa, got '$resolved_success'"
    else
        pass "test-mode success payment method ignores lifecycle probe alias and uses pm_card_visa"
    fi
    if [ "$resolved_declined" != "pm_card_chargeCustomerFail" ]; then
        fail "test-mode declined payment method should default to pm_card_chargeCustomerFail, got '$resolved_declined'"
    else
        pass "test-mode declined payment method defaults to pm_card_chargeCustomerFail"
    fi
    if [ "$resolved_requires_action" != "pm_card_authenticationRequired" ]; then
        fail "test-mode requires-action payment method should default to pm_card_authenticationRequired, got '$resolved_requires_action'"
    else
        pass "test-mode requires-action payment method defaults to pm_card_authenticationRequired"
    fi
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

test_contract_verifier_accepts_success_paid_contract() {
    if ! run_verify_contract_helper \
        "success_paid" \
        "200" \
        "200" \
        '{"billing_plan":"shared","stripe_invoice_id":"in_123","subscription_cycle_anchor_at":"2026-05-19T00:00:00Z"}' \
        '{"upgrade_ready": false}'; then
        fail "success-paid contract should verify successfully"
        return
    fi
    pass "verify_contract_expectations accepts the success-paid contract"
}

test_contract_verifier_accepts_requires_action_retry_contract() {
    if ! run_verify_contract_helper \
        "requires_action_402" \
        "402" \
        "402" \
        '{"error":"payment_required","code":"invoice_payment_intent_requires_action"}' \
        '{"upgrade_ready": true}'; then
        fail "requires-action retry contract should verify successfully"
        return
    fi
    pass "verify_contract_expectations accepts the requires-action retry contract"
}

echo "=== capture_upgrade_trust_ratchet_evidence contract tests ==="
test_payment_methods_are_parameterized_not_hardcoded
test_stripe_attach_failure_is_fail_closed_with_owner_message
test_setup_artifact_omits_raw_payment_method_value
test_upgrade_status_probe_has_404_fallback_contract
test_test_mode_ignores_lifecycle_probe_payment_method_aliases
test_contract_verifier_fails_closed_on_http_mismatch
test_contract_verifier_accepts_success_paid_contract
test_contract_verifier_accepts_decline_retry_contract
test_contract_verifier_accepts_requires_action_retry_contract
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
