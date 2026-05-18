#!/usr/bin/env bash
# Shared Stripe payment-method attach/default/detach helpers.
# shellcheck disable=SC2034
#
# Caller-owned prerequisites:
# - stripe_request from scripts/lib/stripe_request.sh
#
# Exports:
# - STRIPE_ATTACHED_PAYMENT_METHOD_ID
# - STRIPE_PAYMENT_METHOD_ERROR_MESSAGE

STRIPE_ATTACHED_PAYMENT_METHOD_ID=""
STRIPE_PAYMENT_METHOD_ERROR_MESSAGE=""

stripe_payment_method_set_error() {
    STRIPE_PAYMENT_METHOD_ERROR_MESSAGE="$1"
}

stripe_payment_method_extract_field() {
    local json_body="$1"
    local field_name="$2"

    python3 - "$json_body" "$field_name" <<'PY' || true
import json
import sys

payload = json.loads(sys.argv[1])
field_name = sys.argv[2]
value = payload.get(field_name, "")
if value is None:
    print("")
elif isinstance(value, (int, float, bool)):
    print(str(value).lower() if isinstance(value, bool) else str(value))
else:
    print(str(value))
PY
}

stripe_attach_payment_method_to_customer() {
    local payment_method_id="$1"
    local customer_id="$2"
    local response_body=""

    STRIPE_ATTACHED_PAYMENT_METHOD_ID=""
    STRIPE_PAYMENT_METHOD_ERROR_MESSAGE=""

    if [ -z "$payment_method_id" ] || [ -z "$customer_id" ]; then
        stripe_payment_method_set_error "payment method id and customer id are required"
        return 1
    fi

    if ! stripe_request POST "/v1/payment_methods/${payment_method_id}/attach" -d "customer=${customer_id}"; then
        stripe_payment_method_set_error "curl failure while attaching payment method: ${STRIPE_BODY:-unknown}"
        return 1
    fi
    if [ "${STRIPE_HTTP_CODE:-}" != "200" ]; then
        stripe_payment_method_set_error "attach payment method failed with HTTP ${STRIPE_HTTP_CODE:-unknown}"
        return 1
    fi

    response_body="${STRIPE_BODY:-}"
    if [ -z "$response_body" ]; then
        response_body='{}'
    fi
    STRIPE_ATTACHED_PAYMENT_METHOD_ID="$(stripe_payment_method_extract_field "$response_body" "id")"
    if [ -z "$STRIPE_ATTACHED_PAYMENT_METHOD_ID" ]; then
        stripe_payment_method_set_error "attach payment method response missing id"
        return 1
    fi
}

stripe_set_default_payment_method_for_customer() {
    local customer_id="$1"
    local payment_method_id="$2"

    STRIPE_PAYMENT_METHOD_ERROR_MESSAGE=""

    if [ -z "$customer_id" ] || [ -z "$payment_method_id" ]; then
        stripe_payment_method_set_error "customer id and payment method id are required"
        return 1
    fi

    if ! stripe_request POST "/v1/customers/${customer_id}" \
        -d "invoice_settings[default_payment_method]=${payment_method_id}"; then
        stripe_payment_method_set_error "curl failure while setting default payment method: ${STRIPE_BODY:-unknown}"
        return 1
    fi
    if [ "${STRIPE_HTTP_CODE:-}" != "200" ]; then
        stripe_payment_method_set_error "set default payment method failed with HTTP ${STRIPE_HTTP_CODE:-unknown}"
        return 1
    fi
}

stripe_detach_payment_method() {
    local payment_method_id="$1"

    STRIPE_PAYMENT_METHOD_ERROR_MESSAGE=""

    if [ -z "$payment_method_id" ]; then
        stripe_payment_method_set_error "payment method id is required"
        return 1
    fi

    if ! stripe_request POST "/v1/payment_methods/${payment_method_id}/detach"; then
        stripe_payment_method_set_error "curl failure while detaching payment method: ${STRIPE_BODY:-unknown}"
        return 1
    fi
    if [ "${STRIPE_HTTP_CODE:-}" != "200" ]; then
        stripe_payment_method_set_error "detach payment method failed with HTTP ${STRIPE_HTTP_CODE:-unknown}"
        return 1
    fi
}
