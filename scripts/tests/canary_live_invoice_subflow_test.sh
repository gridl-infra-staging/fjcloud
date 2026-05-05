#!/usr/bin/env bash
# Red contract test for Stage 5 live invoice/pay/refund/webhook canary subflow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANARY_SCRIPT="$REPO_ROOT/scripts/canary/customer_loop_synthetic.sh"

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

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

if [ ! -f "$CANARY_SCRIPT" ]; then
    fail "canary script exists at scripts/canary/customer_loop_synthetic.sh"
    exit 1
fi

# shellcheck source=scripts/canary/customer_loop_synthetic.sh
source "$CANARY_SCRIPT"

reset_failure_state() {
    FLOW_FAILED=0
    FLOW_FAILURE_STEP=""
    FLOW_FAILURE_DETAIL=""
}

test_run_live_create_invoice_step_calls_expected_stripe_sequence() {
    reset_failure_state
    CANARY_STRIPE_CUSTOMER_ID="cus_live_123"
    CANARY_LIVE_INVOICE_ID=""
    CANARY_LIVE_CHARGE_ID=""

    local call_log call_index=0 rc calls
    call_log="$(mktemp)"
    trap 'rm -f "'"$call_log"'"; trap - RETURN' RETURN

    stripe_request() {
        local method="$1" path="$2"
        shift 2
        call_index=$((call_index + 1))
        printf '%s|%s|%s\n' "$method" "$path" "$*" >> "$call_log"

        # Stripe API 2026-01-28.clover: invoices with charge_automatically
        # may auto-pay on finalize, and the Invoice object no longer carries
        # a `charge` field — the canary fetches the charge via
        # GET /v1/charges?customer=… instead. Mock that 5-call sequence here.
        case "$call_index" in
            1)
                STRIPE_HTTP_CODE="200"
                STRIPE_BODY='{"id":"in_live_123"}'
                ;;
            2)
                STRIPE_HTTP_CODE="200"
                STRIPE_BODY='{"id":"ii_live_123"}'
                ;;
            3)
                # Finalize response without status="paid" forces the
                # canary to call /pay explicitly (call #4).
                STRIPE_HTTP_CODE="200"
                STRIPE_BODY='{"id":"in_live_123","status":"open"}'
                ;;
            4)
                STRIPE_HTTP_CODE="200"
                STRIPE_BODY='{"id":"in_live_123","status":"paid"}'
                ;;
            5)
                STRIPE_HTTP_CODE="200"
                STRIPE_BODY='{"data":[{"id":"ch_live_123"}]}'
                ;;
            *)
                STRIPE_HTTP_CODE="500"
                STRIPE_BODY='{"error":"unexpected call"}'
                ;;
        esac
        return 0
    }

    rc=0
    run_live_create_invoice_step || rc=$?
    assert_eq "$rc" "0" "run_live_create_invoice_step succeeds on 200 responses"

    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_contains "$calls" "POST|/v1/invoices" "invoice step calls POST /v1/invoices"
    assert_contains "$calls" "POST|/v1/invoiceitems" "invoice step calls POST /v1/invoiceitems"
    assert_contains "$calls" "amount=50" "invoice item amount remains 50 cents"
    assert_contains "$calls" "POST|/v1/invoices/in_live_123/finalize" "invoice step finalizes invoice"
    assert_contains "$calls" "POST|/v1/invoices/in_live_123/pay" "invoice step pays invoice when finalize did not auto-pay"
    assert_contains "$calls" "GET|/v1/charges?customer=cus_live_123&limit=1" "invoice step retrieves charge via charges list endpoint"
    assert_eq "$CANARY_LIVE_INVOICE_ID" "in_live_123" "invoice id captured from create/pay sequence"
    assert_eq "$CANARY_LIVE_CHARGE_ID" "ch_live_123" "charge id captured from charges list response"
}

test_run_live_create_invoice_step_skips_pay_when_finalize_auto_pays() {
    reset_failure_state
    CANARY_STRIPE_CUSTOMER_ID="cus_auto_456"
    CANARY_LIVE_INVOICE_ID=""
    CANARY_LIVE_CHARGE_ID=""

    local call_log call_index=0 rc calls
    call_log="$(mktemp)"
    trap 'rm -f "'"$call_log"'"; trap - RETURN' RETURN

    stripe_request() {
        local method="$1" path="$2"
        shift 2
        call_index=$((call_index + 1))
        printf '%s|%s|%s\n' "$method" "$path" "$*" >> "$call_log"

        case "$call_index" in
            1)
                STRIPE_HTTP_CODE="200"
                STRIPE_BODY='{"id":"in_auto_456"}'
                ;;
            2)
                STRIPE_HTTP_CODE="200"
                STRIPE_BODY='{"id":"ii_auto_456"}'
                ;;
            3)
                # Finalize returns status="paid" — /pay must be skipped.
                STRIPE_HTTP_CODE="200"
                STRIPE_BODY='{"id":"in_auto_456","status":"paid"}'
                ;;
            4)
                STRIPE_HTTP_CODE="200"
                STRIPE_BODY='{"data":[{"id":"ch_auto_456"}]}'
                ;;
            *)
                STRIPE_HTTP_CODE="500"
                STRIPE_BODY='{"error":"unexpected call"}'
                ;;
        esac
        return 0
    }

    rc=0
    run_live_create_invoice_step || rc=$?
    assert_eq "$rc" "0" "auto-paid finalize path succeeds"

    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_contains "$calls" "POST|/v1/invoices/in_auto_456/finalize" "auto-paid path still finalizes"
    if printf '%s\n' "$calls" | grep -q "POST|/v1/invoices/in_auto_456/pay"; then
        fail "auto-paid finalize must not call /pay"
    else
        pass "auto-paid finalize must not call /pay"
    fi
    assert_eq "$CANARY_LIVE_CHARGE_ID" "ch_auto_456" "charge id captured on auto-pay path"
}

test_run_live_create_invoice_step_marks_failure_on_non_200() {
    reset_failure_state
    CANARY_STRIPE_CUSTOMER_ID="cus_live_123"

    stripe_request() {
        STRIPE_HTTP_CODE="500"
        STRIPE_BODY='{"error":"boom"}'
        return 0
    }

    local rc=0
    run_live_create_invoice_step || rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "run_live_create_invoice_step exits non-zero on non-200"
    else
        fail "run_live_create_invoice_step exits non-zero on non-200"
    fi
    assert_eq "$FLOW_FAILED" "1" "non-200 invoice create marks failure"
    assert_eq "$FLOW_FAILURE_STEP" "live_create_invoice" "invoice create failure step owner remains live_create_invoice"
}

test_run_live_refund_step_calls_refunds_with_charge() {
    reset_failure_state
    CANARY_LIVE_CHARGE_ID="ch_live_123"
    CANARY_LIVE_REFUND_ID=""

    local call_log rc calls
    call_log="$(mktemp)"
    trap 'rm -f "'"$call_log"'"; trap - RETURN' RETURN

    stripe_request() {
        local method="$1" path="$2"
        shift 2
        printf '%s|%s|%s\n' "$method" "$path" "$*" >> "$call_log"
        STRIPE_HTTP_CODE="200"
        STRIPE_BODY='{"id":"re_live_123"}'
        return 0
    }

    rc=0
    run_live_refund_step || rc=$?
    assert_eq "$rc" "0" "run_live_refund_step succeeds on 200 response"
    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_contains "$calls" "POST|/v1/refunds" "refund step calls POST /v1/refunds"
    assert_contains "$calls" "charge=ch_live_123" "refund step passes charge id"
    assert_contains "$calls" "reason=requested_by_customer" "refund step passes requested_by_customer reason"
    assert_eq "$CANARY_LIVE_REFUND_ID" "re_live_123" "refund id captured from response"
}

test_run_live_find_payment_event_step_discovers_exact_event_id() {
    reset_failure_state
    CANARY_LIVE_INVOICE_ID="in_live_123"
    CANARY_LIVE_PAYMENT_EVENT_ID=""

    local call_log rc calls
    call_log="$(mktemp)"
    trap 'rm -f "'"$call_log"'"; trap - RETURN' RETURN

    stripe_request() {
        local method="$1" path="$2"
        shift 2
        printf '%s|%s|%s\n' "$method" "$path" "$*" >> "$call_log"
        STRIPE_HTTP_CODE="200"
        STRIPE_BODY='{"data":[{"id":"evt_other","type":"invoice.payment_succeeded","data":{"object":{"id":"in_other"}}},{"id":"evt_live_123","type":"invoice.payment_succeeded","data":{"object":{"id":"in_live_123"}}}]}'
        return 0
    }

    rc=0
    run_live_find_payment_event_step || rc=$?
    assert_eq "$rc" "0" "run_live_find_payment_event_step succeeds when matching event exists"
    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_contains "$calls" "GET|/v1/events?type=invoice.payment_succeeded&limit=25" "event lookup uses invoice.payment_succeeded filter"
    assert_eq "$CANARY_LIVE_PAYMENT_EVENT_ID" "evt_live_123" "matching event id captured for webhook lookup"
}

test_run_live_webhook_verify_step_polls_admin_route_until_row_exists() {
    reset_failure_state
    ADMIN_KEY="admin_test_key"
    CANARY_LIVE_PAYMENT_EVENT_ID="evt_live_123"

    local call_log attempt=0 rc calls
    call_log="$(mktemp)"
    trap 'rm -f "'"$call_log"'"; trap - RETURN' RETURN

    admin_call() {
        local method="$1" path="$2"
        shift 2
        attempt=$((attempt + 1))
        printf '%s|%s\n' "$method" "$path" >> "$call_log"
        if [ "$attempt" -eq 1 ]; then
            printf '{"error":"not found"}\n404'
        else
            printf '{"stripe_event_id":"evt_live_123"}\n200'
        fi
    }

    sleep() { :; }

    rc=0
    run_live_webhook_verify_step || rc=$?
    assert_eq "$rc" "0" "run_live_webhook_verify_step succeeds once admin route returns persisted row"
    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_contains "$calls" "GET|/admin/webhook-events?stripe_event_id=evt_live_123" "webhook verify calls admin webhook-events route"
}

test_run_live_webhook_verify_step_marks_failure_when_row_missing() {
    reset_failure_state
    ADMIN_KEY="admin_test_key"
    CANARY_LIVE_PAYMENT_EVENT_ID="evt_missing"

    admin_call() {
        printf '{"error":"not found"}\n404'
    }

    sleep() { :; }

    local rc=0
    run_live_webhook_verify_step || rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "run_live_webhook_verify_step exits non-zero when webhook row never appears"
    else
        fail "run_live_webhook_verify_step exits non-zero when webhook row never appears"
    fi
    assert_eq "$FLOW_FAILED" "1" "missing-row webhook verify marks failure"
    assert_eq "$FLOW_FAILURE_STEP" "live_webhook_verify" "missing-row webhook verify failure owner remains live_webhook_verify"
}

test_run_live_cleanup_step_refunds_paid_charge_before_any_void() {
    CANARY_LIVE_CHARGE_ID="ch_live_123"
    CANARY_LIVE_REFUND_ID=""
    CANARY_LIVE_INVOICE_ID="in_live_123"

    local call_log calls
    call_log="$(mktemp)"
    trap 'rm -f "'"$call_log"'"; trap - RETURN' RETURN

    stripe_request() {
        local method="$1" path="$2"
        shift 2
        printf '%s|%s|%s\n' "$method" "$path" "$*" >> "$call_log"
        STRIPE_HTTP_CODE="200"
        STRIPE_BODY='{"id":"re_cleanup"}'
        return 0
    }

    run_live_cleanup_step
    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_contains "$calls" "POST|/v1/refunds" "cleanup attempts refund when paid charge is not yet refunded"
    assert_not_contains "$calls" "/void" "cleanup does not void invoice when paid charge path is active"
}

test_run_live_cleanup_step_voids_unpaid_invoice() {
    CANARY_LIVE_CHARGE_ID=""
    CANARY_LIVE_REFUND_ID=""
    CANARY_LIVE_INVOICE_ID="in_unpaid_123"

    local call_log calls
    call_log="$(mktemp)"
    trap 'rm -f "'"$call_log"'"; trap - RETURN' RETURN

    stripe_request() {
        local method="$1" path="$2"
        shift 2
        printf '%s|%s|%s\n' "$method" "$path" "$*" >> "$call_log"
        STRIPE_HTTP_CODE="200"
        STRIPE_BODY='{"id":"in_unpaid_123"}'
        return 0
    }

    run_live_cleanup_step
    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_contains "$calls" "POST|/v1/invoices/in_unpaid_123/void" "cleanup voids unpaid invoice when charge was never created"
}

main_test() {
    echo "=== canary_live_invoice_subflow_test.sh ==="
    echo ""

    test_run_live_create_invoice_step_calls_expected_stripe_sequence
    test_run_live_create_invoice_step_skips_pay_when_finalize_auto_pays
    test_run_live_create_invoice_step_marks_failure_on_non_200
    test_run_live_refund_step_calls_refunds_with_charge
    test_run_live_find_payment_event_step_discovers_exact_event_id
    test_run_live_webhook_verify_step_polls_admin_route_until_row_exists
    test_run_live_webhook_verify_step_marks_failure_when_row_missing
    test_run_live_cleanup_step_refunds_paid_charge_before_any_void
    test_run_live_cleanup_step_voids_unpaid_invoice

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main_test "$@"
