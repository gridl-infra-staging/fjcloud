#!/usr/bin/env bash
# Validate Stripe test-mode billing lifecycle and emit machine-readable JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation_json.sh"
source "$SCRIPT_DIR/lib/stripe_checks.sh"

# Local aliases for shared validation helpers (short names used throughout).
json_get_field() { validation_json_get_field "$@"; }
append_step() { validation_append_step "$@"; }
emit_result() { validation_emit_result "$@"; }

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

stripe_request() {
    local method="$1"
    local path="$2"
    shift 2

    local stripe_secret_key="$STRIPE_SECRET_KEY_EFFECTIVE"
    local response
    if ! response="$(curl -sS -w "\n%{http_code}" -u "$stripe_secret_key:" -X "$method" "$STRIPE_API_BASE$path" "$@" 2>&1)"; then
        STRIPE_HTTP_CODE="000"
        STRIPE_BODY="$response"
        return 1
    fi

    STRIPE_HTTP_CODE="$(printf '%s\n' "$response" | tail -1)"
    STRIPE_BODY="$(printf '%s\n' "$response" | sed '$d')"
    return 0
}

STRIPE_API_BASE="${STRIPE_API_BASE:-https://api.stripe.com}"
STRIPE_SECRET_KEY_EFFECTIVE=""

require_stripe_api_base

if ! STRIPE_SECRET_KEY_EFFECTIVE="$(resolve_stripe_secret_key)"; then
    append_step "require_stripe_secret_key" false "STRIPE_SECRET_KEY is unset"
    emit_result false
    exit 1
fi

if [[ "$STRIPE_SECRET_KEY_EFFECTIVE" != sk_test_* ]]; then
    append_step "require_test_mode_stripe_secret_key" false "Resolved STRIPE_SECRET_KEY must start with sk_test_"
    emit_result false
    exit 1
fi

if ! stripe_request POST "/v1/customers" -d "description=fjcloud-stage5-validation"; then
    append_step "create_customer" false "curl failure while creating customer: ${STRIPE_BODY:-unknown error}"
    emit_result false
    exit 1
fi
if [ "$STRIPE_HTTP_CODE" != "200" ] && [ "$STRIPE_HTTP_CODE" != "201" ]; then
    append_step "create_customer" false "Stripe customer creation failed with HTTP $STRIPE_HTTP_CODE"
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

if ! stripe_request POST "/v1/payment_methods/pm_card_visa/attach" -d "customer=$CUSTOMER_ID"; then
    append_step "attach_payment_method" false "curl failure while attaching payment method: ${STRIPE_BODY:-unknown error}"
    emit_result false
    exit 1
fi
if [ "$STRIPE_HTTP_CODE" != "200" ]; then
    append_step "attach_payment_method" false "Attach payment method failed with HTTP $STRIPE_HTTP_CODE"
    emit_result false
    exit 1
fi

if ! stripe_request POST "/v1/customers/$CUSTOMER_ID" -d "invoice_settings[default_payment_method]=pm_card_visa"; then
    append_step "attach_payment_method" false "curl failure while setting default payment method: ${STRIPE_BODY:-unknown error}"
    emit_result false
    exit 1
fi
if [ "$STRIPE_HTTP_CODE" != "200" ]; then
    append_step "attach_payment_method" false "Set default payment method failed with HTTP $STRIPE_HTTP_CODE"
    emit_result false
    exit 1
fi
append_step "attach_payment_method" true "Attached and set pm_card_visa as default"

if ! stripe_request POST "/v1/invoiceitems" -d "customer=$CUSTOMER_ID" -d "amount=100" -d "currency=usd" -d "description=stage5-validation"; then
    append_step "create_and_pay_invoice" false "curl failure while creating invoice item: ${STRIPE_BODY:-unknown error}"
    emit_result false
    exit 1
fi
if [ "$STRIPE_HTTP_CODE" != "200" ] && [ "$STRIPE_HTTP_CODE" != "201" ]; then
    append_step "create_and_pay_invoice" false "Create invoice item failed with HTTP $STRIPE_HTTP_CODE"
    emit_result false
    exit 1
fi

if ! stripe_request POST "/v1/invoices" -d "customer=$CUSTOMER_ID" -d "collection_method=charge_automatically" -d "auto_advance=false"; then
    append_step "create_and_pay_invoice" false "curl failure while creating invoice: ${STRIPE_BODY:-unknown error}"
    emit_result false
    exit 1
fi
if [ "$STRIPE_HTTP_CODE" != "200" ] && [ "$STRIPE_HTTP_CODE" != "201" ]; then
    append_step "create_and_pay_invoice" false "Create invoice failed with HTTP $STRIPE_HTTP_CODE"
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
    append_step "create_and_pay_invoice" false "Pay invoice failed with HTTP $STRIPE_HTTP_CODE"
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
