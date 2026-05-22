#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# Regression test: run_wait_for_paid_invoice_step OOB fallback must not
# poison FLOW_FAILED when Stripe-side confirms paid status.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../validate_full_vm_lifecycle_prod.sh
source "$REPO_ROOT/scripts/validate_full_vm_lifecycle_prod.sh"

assert_equals() {
    local actual="$1"
    local expected="$2"
    local context="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: ${context} expected=${expected} actual=${actual}" >&2
        exit 1
    fi
}

TEST_LOGS=()
TEST_ADMIN_CALLS=()
TEST_STRIPE_REQUEST_CALLS=()
MOCK_STRIPE_HTTP_CODE="200"
MOCK_STRIPE_BODY=""
MOCK_ADMIN_HTTP_CODE="200"
MOCK_ADMIN_BODY="[]"

log() {
    TEST_LOGS+=("$*")
}

mark_failure() {
    local step_name="$1"
    local detail_message="$2"
    if [ "${FLOW_FAILED:-0}" -eq 0 ]; then
        FLOW_FAILED=1
        FLOW_FAILURE_STEP="$step_name"
        FLOW_FAILURE_DETAIL="$detail_message"
    fi
}

capture_json_response() {
    TEST_ADMIN_CALLS+=("$*")
    HTTP_RESPONSE_CODE="$MOCK_ADMIN_HTTP_CODE"
    HTTP_RESPONSE_BODY="$MOCK_ADMIN_BODY"
}

stripe_request() {
    TEST_STRIPE_REQUEST_CALLS+=("$*")
    STRIPE_HTTP_CODE="$MOCK_STRIPE_HTTP_CODE"
    STRIPE_BODY="$MOCK_STRIPE_BODY"
}

json_get_field() {
    python3 -c "import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],''))" "$1" "$2"
}

reset_test_state() {
    FLOW_FAILED=0
    FLOW_FAILURE_STEP=""
    FLOW_FAILURE_DETAIL=""
    STRIPE_PAY_OUT_OF_BAND="1"
    LIFECYCLE_INVOICE_ID="inv_test_123"
    LIFECYCLE_STRIPE_INVOICE_ID="in_test_stripe_456"
    CANARY_CUSTOMER_ID="cust_test_789"
    STRIPE_SECRET_KEY_flapjack_cloud="sk_live_test_regression"
    STRIPE_SECRET_KEY_EFFECTIVE=""
    STRIPE_API_BASE="https://api.stripe.com"
    TEST_LOGS=()
    TEST_ADMIN_CALLS=()
    TEST_STRIPE_REQUEST_CALLS=()
    MOCK_ADMIN_HTTP_CODE="200"
    MOCK_ADMIN_BODY="[]"
    MOCK_STRIPE_HTTP_CODE="200"
    MOCK_STRIPE_BODY='{"id":"in_test_stripe_456","status":"paid","amount_paid":0}'
}

test_oob_fallback_does_not_poison_flow_failed() {
    reset_test_state
    MOCK_ADMIN_BODY='[{"id":"inv_test_123","status":"open","paid_at":null}]'

    run_wait_for_paid_invoice_step
    local rc=$?

    assert_equals "$rc" "0" "oob_fallback_returns_success"
    assert_equals "$FLOW_FAILED" "0" "oob_fallback_flow_failed_must_be_zero"
    assert_equals "$FLOW_FAILURE_STEP" "" "oob_fallback_failure_step_must_be_empty"
}

test_oob_fallback_stripe_not_paid_marks_failure() {
    reset_test_state
    MOCK_ADMIN_BODY='[{"id":"inv_test_123","status":"open","paid_at":null}]'
    MOCK_STRIPE_BODY='{"id":"in_test_stripe_456","status":"open","amount_paid":0}'

    if run_wait_for_paid_invoice_step; then
        echo "FAIL: stripe-not-paid should make step fail" >&2
        exit 1
    fi

    assert_equals "$FLOW_FAILED" "1" "stripe_not_paid_marks_failure"
    assert_equals "$FLOW_FAILURE_STEP" "invoice_paid" "stripe_not_paid_step_name"
}

test_db_convergence_succeeds_without_stripe_fallback() {
    reset_test_state
    MOCK_ADMIN_BODY='[{"id":"inv_test_123","status":"paid","paid_at":"2026-05-21T10:00:00Z"}]'

    run_wait_for_paid_invoice_step

    assert_equals "$FLOW_FAILED" "0" "db_convergence_flow_not_failed"
    assert_equals "${#TEST_STRIPE_REQUEST_CALLS[@]}" "0" "db_convergence_no_stripe_call"
}

main() {
    test_oob_fallback_does_not_poison_flow_failed
    test_oob_fallback_stripe_not_paid_marks_failure
    test_db_convergence_succeeds_without_stripe_fallback
    echo "PASS: lifecycle wait-paid step assertions succeeded"
}

main "$@"
