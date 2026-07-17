#!/usr/bin/env bash
# shellcheck disable=SC1091
# Validate Stripe test-mode billing lifecycle and emit machine-readable JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/validation_json.sh
source "$SCRIPT_DIR/lib/validation_json.sh"
# shellcheck source=scripts/lib/stripe_checks.sh
source "$SCRIPT_DIR/lib/stripe_checks.sh"
# shellcheck source=scripts/lib/stripe_request.sh
source "$SCRIPT_DIR/lib/stripe_request.sh"
# shellcheck source=scripts/lib/stripe_payment_methods.sh
source "$SCRIPT_DIR/lib/stripe_payment_methods.sh"

# Local aliases for shared validation helpers (short names used throughout).
json_get_field() { validation_json_get_field "$@"; }
append_step() { validation_append_step "$@"; }
emit_result() { validation_emit_result "$@"; }

usage() {
    cat <<'EOF'
Usage: scripts/validate-stripe.sh [--live-cutover | --test-clock]

Options:
  --live-cutover  Enable explicit live Stripe key validation mode.
                  Requires STRIPE_LIVE_CUTOVER=1.
  --test-clock    Drive a Stripe test-clock lifecycle (create / advance /
                  delete) against the test-mode API instead of the default
                  customer/invoice lifecycle. Mutually exclusive with
                  --live-cutover.
EOF
}

STRIPE_KEY_POLICY_MODE="test_only"
LIVE_CUTOVER_REQUESTED=0
TEST_CLOCK_REQUESTED=0
TEST_CLOCK_ID=""
TEST_CLOCK_READY_MAX_POLLS="${TEST_CLOCK_READY_MAX_POLLS:-30}"
TEST_CLOCK_READY_POLL_INTERVAL_SECONDS="${TEST_CLOCK_READY_POLL_INTERVAL_SECONDS:-2}"

stripe_key_prefix_policy_allows_key() {
    local key="$1"
    local policy_mode="$2"

    case "$policy_mode" in
        test_only)
            [[ "$key" == sk_test_* || "$key" == rk_test_* ]]
            ;;
        live_cutover)
            [[ "$key" == sk_live_* || "$key" == rk_live_* ]]
            ;;
        *)
            return 1
            ;;
    esac
}

stripe_key_prefix_policy_requirement_message() {
    local policy_mode="$1"

    case "$policy_mode" in
        test_only)
            printf 'STRIPE_SECRET_KEY must start with sk_test_ or rk_test_'
            ;;
        live_cutover)
            printf 'STRIPE_SECRET_KEY must start with sk_live_ or rk_live_ when --live-cutover is requested'
            ;;
        *)
            printf 'STRIPE_SECRET_KEY has an unsupported prefix policy'
            ;;
    esac
}

# Live-cutover verification is auth-only; it must not depend on test-mode
# fixtures like pm_card_visa or create/purchase flows.
validate_live_cutover_key_auth() {
    if ! stripe_request GET "/v1/balance"; then
        append_step "verify_live_key_auth" false "curl failure while validating live key auth: ${STRIPE_BODY:-unknown error}"
        return 1
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ]; then
        append_step "verify_live_key_auth" false "Stripe live key auth check failed with HTTP $STRIPE_HTTP_CODE$(stripe_error_context)"
        return 1
    fi

    append_step "verify_live_key_auth" true "Validated live key auth with Stripe GET /v1/balance"
    return 0
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --live-cutover)
                STRIPE_KEY_POLICY_MODE="live_cutover"
                LIVE_CUTOVER_REQUESTED=1
                ;;
            --test-clock)
                TEST_CLOCK_REQUESTED=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                append_step "parse_args" false "Unknown argument: $1"
                emit_result false
                exit 1
                ;;
        esac
        shift
    done

    if [ "$LIVE_CUTOVER_REQUESTED" -eq 1 ] && [ "$TEST_CLOCK_REQUESTED" -eq 1 ]; then
        append_step "parse_args" false "--test-clock and --live-cutover are mutually exclusive"
        emit_result false
        exit 1
    fi
}

json_get_path() {
    local json_body="$1"
    local field_path="$2"
    python3 - "$json_body" "$field_path" <<'PY' || true
import json
import sys

body = sys.argv[1]
field_path = sys.argv[2]
try:
    data = json.loads(body)
except Exception:
    print("")
    raise SystemExit(0)

value = data
for segment in field_path.split("."):
    if isinstance(value, dict):
        value = value.get(segment, "")
    else:
        value = ""
        break

if value is None:
    print("")
elif isinstance(value, (int, float, bool)):
    print(str(value).lower() if isinstance(value, bool) else str(value))
else:
    print(str(value))
PY
}

stripe_error_context() {
    local request_id="${STRIPE_REQUEST_ID:-}"
    local error_type error_code error_message request_log_url
    local parts=()
    local joined=""
    local part=""

    error_type="$(json_get_path "${STRIPE_BODY:-}" "error.type")"
    error_code="$(json_get_path "${STRIPE_BODY:-}" "error.code")"
    error_message="$(json_get_path "${STRIPE_BODY:-}" "error.message")"
    request_log_url="$(json_get_path "${STRIPE_BODY:-}" "error.request_log_url")"

    if [ -n "$request_id" ]; then
        parts+=("request_id=$request_id")
    fi
    if [ -n "$error_type" ]; then
        parts+=("type=$error_type")
    fi
    if [ -n "$error_code" ]; then
        parts+=("code=$error_code")
    fi
    if [ -n "$error_message" ]; then
        parts+=("message=$error_message")
    fi
    if [ -n "$request_log_url" ]; then
        parts+=("log=$request_log_url")
    fi

    for part in "${parts[@]}"; do
        if [ -n "$joined" ]; then
            joined="$joined; "
        fi
        joined="$joined$part"
    done

    if [ -n "$joined" ]; then
        printf ' (%s)' "$joined"
    fi
}

# The Stripe secret is sent via Basic Auth, so this live validation script must
# never allow an env override to redirect requests to a non-Stripe host.
require_stripe_api_base() {
    case "$STRIPE_API_BASE" in
        "https://api.stripe.com"|"https://api.stripe.com/")
            STRIPE_API_BASE="https://api.stripe.com"
            return 0
            ;;
    esac

    append_step "require_stripe_api_base" false "STRIPE_API_BASE must be https://api.stripe.com"
    emit_result false
    exit 1
}

STRIPE_API_BASE="${STRIPE_API_BASE:-https://api.stripe.com}"
STRIPE_SECRET_KEY_EFFECTIVE=""
STRIPE_REQUEST_ID=""

parse_args "$@"
require_stripe_api_base

if ! STRIPE_SECRET_KEY_EFFECTIVE="$(resolve_stripe_secret_key)"; then
    append_step "require_stripe_secret_key" false "STRIPE_SECRET_KEY is unset"
    emit_result false
    exit 1
fi

if [ "$LIVE_CUTOVER_REQUESTED" -eq 1 ]; then
    if [ "${STRIPE_LIVE_CUTOVER:-0}" != "1" ]; then
        append_step "require_live_cutover_control" false "Set STRIPE_LIVE_CUTOVER=1 to authorize --live-cutover validation"
        emit_result false
        exit 1
    fi
    append_step "live_cutover_mode_enabled" true "Explicit live cutover mode enabled for Stripe validation"
fi

if ! stripe_key_prefix_policy_allows_key "$STRIPE_SECRET_KEY_EFFECTIVE" "$STRIPE_KEY_POLICY_MODE"; then
    if [ "$STRIPE_KEY_POLICY_MODE" = "live_cutover" ]; then
        append_step "require_live_cutover_stripe_secret_key" false "$(stripe_key_prefix_policy_requirement_message "$STRIPE_KEY_POLICY_MODE")"
    else
        append_step "require_test_mode_stripe_secret_key" false "$(stripe_key_prefix_policy_requirement_message "$STRIPE_KEY_POLICY_MODE")"
    fi
    emit_result false
    exit 1
fi

if [ "$STRIPE_KEY_POLICY_MODE" = "live_cutover" ]; then
    if ! validate_live_cutover_key_auth; then
        emit_result false
        exit 1
    fi
    emit_result true
    exit 0
fi

# Best-effort test-clock cleanup so a created clock is always torn down.
cleanup_test_clock() {
    if [ -z "$TEST_CLOCK_ID" ]; then
        return 0
    fi
    local clock_id="$TEST_CLOCK_ID"
    TEST_CLOCK_ID=""
    if ! stripe_request DELETE "/v1/test_helpers/test_clocks/$clock_id"; then
        append_step "delete_test_clock" false "curl failure while deleting test clock $clock_id: ${STRIPE_BODY:-unknown error}"
        return 1
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ]; then
        append_step "delete_test_clock" false "Delete test clock $clock_id failed with HTTP $STRIPE_HTTP_CODE$(stripe_error_context)"
        return 1
    fi
    append_step "delete_test_clock" true "Deleted test clock $clock_id"
    return 0
}

wait_for_test_clock_ready() {
    local clock_id="$1"
    local attempt status

    attempt=1
    while [ "$attempt" -le "$TEST_CLOCK_READY_MAX_POLLS" ]; do
        if ! stripe_request GET "/v1/test_helpers/test_clocks/$clock_id"; then
            append_step "wait_test_clock_ready" false "curl failure while polling test clock $clock_id: ${STRIPE_BODY:-unknown error}"
            return 1
        fi
        if [ "$STRIPE_HTTP_CODE" != "200" ]; then
            append_step "wait_test_clock_ready" false "Poll test clock $clock_id failed with HTTP $STRIPE_HTTP_CODE$(stripe_error_context)"
            return 1
        fi

        status="$(json_get_field "$STRIPE_BODY" "status")"
        if [ "$status" = "ready" ]; then
            append_step "wait_test_clock_ready" true "Test clock $clock_id reached ready after $attempt poll(s)"
            return 0
        fi
        if [ -z "$status" ]; then
            append_step "wait_test_clock_ready" false "Stripe response did not include test clock status while polling $clock_id"
            return 1
        fi

        if [ "$attempt" -lt "$TEST_CLOCK_READY_MAX_POLLS" ]; then
            sleep "$TEST_CLOCK_READY_POLL_INTERVAL_SECONDS"
        fi
        attempt=$((attempt + 1))
    done

    append_step "wait_test_clock_ready" false "Test clock $clock_id did not reach ready after $TEST_CLOCK_READY_MAX_POLLS poll(s); last status=$status"
    return 1
}

finish_test_clock_validation() {
    local passed="$1"

    trap - EXIT
    if [ -n "$TEST_CLOCK_ID" ]; then
        if ! cleanup_test_clock; then
            passed=false
        fi
    fi

    emit_result "$passed"
    if [ "$passed" = true ]; then
        exit 0
    fi
    exit 1
}

if [ "$TEST_CLOCK_REQUESTED" -eq 1 ]; then
    FROZEN_TIME="$(date +%s)"
    if ! stripe_request POST "/v1/test_helpers/test_clocks" -d "frozen_time=$FROZEN_TIME"; then
        append_step "create_test_clock" false "curl failure while creating test clock: ${STRIPE_BODY:-unknown error}"
        emit_result false
        exit 1
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ] && [ "$STRIPE_HTTP_CODE" != "201" ]; then
        append_step "create_test_clock" false "Create test clock failed with HTTP $STRIPE_HTTP_CODE$(stripe_error_context)"
        emit_result false
        exit 1
    fi
    TEST_CLOCK_ID="$(json_get_field "$STRIPE_BODY" "id")"
    if [ -z "$TEST_CLOCK_ID" ]; then
        append_step "create_test_clock" false "Stripe response did not include test clock id"
        emit_result false
        exit 1
    fi
    append_step "create_test_clock" true "Created test clock $TEST_CLOCK_ID at frozen_time=$FROZEN_TIME"

    # Any failure past this point must still tear down the clock.
    trap 'cleanup_test_clock || true' EXIT

    if ! stripe_request POST "/v1/customers" -d "description=fjcloud-test-clock-validation" -d "test_clock=$TEST_CLOCK_ID"; then
        append_step "create_test_clock_customer" false "curl failure while creating test-clock customer: ${STRIPE_BODY:-unknown error}"
        finish_test_clock_validation false
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ] && [ "$STRIPE_HTTP_CODE" != "201" ]; then
        append_step "create_test_clock_customer" false "Create test-clock customer failed with HTTP $STRIPE_HTTP_CODE$(stripe_error_context)"
        finish_test_clock_validation false
    fi
    TEST_CLOCK_CUSTOMER_ID="$(json_get_field "$STRIPE_BODY" "id")"
    if [ -z "$TEST_CLOCK_CUSTOMER_ID" ]; then
        append_step "create_test_clock_customer" false "Stripe response did not include customer id"
        finish_test_clock_validation false
    fi
    append_step "create_test_clock_customer" true "Created customer $TEST_CLOCK_CUSTOMER_ID attached to test clock $TEST_CLOCK_ID"

    # Advance the clock by one hour so the lifecycle is observable.
    ADVANCE_TO="$((FROZEN_TIME + 3600))"
    if ! stripe_request POST "/v1/test_helpers/test_clocks/$TEST_CLOCK_ID/advance" -d "frozen_time=$ADVANCE_TO"; then
        append_step "advance_test_clock" false "curl failure while advancing test clock: ${STRIPE_BODY:-unknown error}"
        finish_test_clock_validation false
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ] && [ "$STRIPE_HTTP_CODE" != "201" ]; then
        append_step "advance_test_clock" false "Advance test clock failed with HTTP $STRIPE_HTTP_CODE$(stripe_error_context)"
        finish_test_clock_validation false
    fi
    append_step "advance_test_clock" true "Advanced test clock $TEST_CLOCK_ID to frozen_time=$ADVANCE_TO"

    if ! wait_for_test_clock_ready "$TEST_CLOCK_ID"; then
        finish_test_clock_validation false
    fi

    finish_test_clock_validation true
fi

if ! stripe_request POST "/v1/customers" -d "description=fjcloud-stage5-validation"; then
    append_step "create_customer" false "curl failure while creating customer: ${STRIPE_BODY:-unknown error}"
    emit_result false
    exit 1
fi
if [ "$STRIPE_HTTP_CODE" != "200" ] && [ "$STRIPE_HTTP_CODE" != "201" ]; then
    append_step "create_customer" false "Stripe customer creation failed with HTTP $STRIPE_HTTP_CODE$(stripe_error_context)"
    emit_result false
    exit 1
fi
CUSTOMER_ID="$(json_get_field "$STRIPE_BODY" "id")"
if [ -z "$CUSTOMER_ID" ]; then
    append_step "create_customer" false "Stripe response did not include customer id"
    emit_result false
    exit 1
fi
append_step "create_customer" true "Created customer $CUSTOMER_ID"

if ! stripe_attach_payment_method_to_customer "pm_card_visa" "$CUSTOMER_ID"; then
    append_step "attach_payment_method" false "${STRIPE_PAYMENT_METHOD_ERROR_MESSAGE:-attach payment method failed}"
    emit_result false
    exit 1
fi
ATTACHED_PAYMENT_METHOD_ID="$STRIPE_ATTACHED_PAYMENT_METHOD_ID"

if ! stripe_set_default_payment_method_for_customer "$CUSTOMER_ID" "$ATTACHED_PAYMENT_METHOD_ID"; then
    append_step "attach_payment_method" false "${STRIPE_PAYMENT_METHOD_ERROR_MESSAGE:-set default payment method failed}$(stripe_error_context)"
    emit_result false
    exit 1
fi
append_step "attach_payment_method" true "Attached and set $ATTACHED_PAYMENT_METHOD_ID as default"

if ! stripe_request POST "/v1/invoiceitems" -d "customer=$CUSTOMER_ID" -d "amount=100" -d "currency=usd" -d "description=stage5-validation"; then
    append_step "create_and_pay_invoice" false "curl failure while creating invoice item: ${STRIPE_BODY:-unknown error}"
    emit_result false
    exit 1
fi
if [ "$STRIPE_HTTP_CODE" != "200" ] && [ "$STRIPE_HTTP_CODE" != "201" ]; then
    append_step "create_and_pay_invoice" false "Create invoice item failed with HTTP $STRIPE_HTTP_CODE$(stripe_error_context)"
    emit_result false
    exit 1
fi

if ! stripe_request POST "/v1/invoices" -d "customer=$CUSTOMER_ID" -d "collection_method=charge_automatically" -d "auto_advance=false"; then
    append_step "create_and_pay_invoice" false "curl failure while creating invoice: ${STRIPE_BODY:-unknown error}"
    emit_result false
    exit 1
fi
if [ "$STRIPE_HTTP_CODE" != "200" ] && [ "$STRIPE_HTTP_CODE" != "201" ]; then
    append_step "create_and_pay_invoice" false "Create invoice failed with HTTP $STRIPE_HTTP_CODE$(stripe_error_context)"
    emit_result false
    exit 1
fi
INVOICE_ID="$(json_get_field "$STRIPE_BODY" "id")"
if [ -z "$INVOICE_ID" ]; then
    append_step "create_and_pay_invoice" false "Stripe response did not include invoice id"
    emit_result false
    exit 1
fi

if ! stripe_request POST "/v1/invoices/$INVOICE_ID/pay"; then
    append_step "create_and_pay_invoice" false "curl failure while paying invoice: ${STRIPE_BODY:-unknown error}"
    emit_result false
    exit 1
fi
if [ "$STRIPE_HTTP_CODE" != "200" ]; then
    append_step "create_and_pay_invoice" false "Pay invoice failed with HTTP $STRIPE_HTTP_CODE$(stripe_error_context)"
    emit_result false
    exit 1
fi

INVOICE_STATUS="$(json_get_field "$STRIPE_BODY" "status")"
if [ "$INVOICE_STATUS" != "paid" ]; then
    append_step "create_and_pay_invoice" false "Invoice $INVOICE_ID pay call returned status '$INVOICE_STATUS'"
    emit_result false
    exit 1
fi
append_step "create_and_pay_invoice" true "Created and paid invoice $INVOICE_ID"

append_step "confirm_payment_succeeded" true "Invoice status is paid"
emit_result true
exit 0
