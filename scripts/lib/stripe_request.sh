#!/usr/bin/env bash
# Shared Stripe request transport helper.
#
# Callers provide:
# - STRIPE_SECRET_KEY_EFFECTIVE
# - STRIPE_API_BASE
#
# Response contract:
# - stripe_request writes STRIPE_HTTP_CODE, STRIPE_BODY, and STRIPE_REQUEST_ID.

# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
# TODO: Document stripe_request.
stripe_request() {
    local method="$1"
    local path="$2"
    shift 2

    local stripe_secret_key="$STRIPE_SECRET_KEY_EFFECTIVE"
    local header_file body_file http_code curl_output
    header_file="$(mktemp)"
    body_file="$(mktemp)"

    if ! curl_output="$(curl -sS -D "$header_file" -o "$body_file" -w "%{http_code}" --config <(printf 'user = "%s:"\n' "$stripe_secret_key") -X "$method" "$STRIPE_API_BASE$path" "$@" 2>&1)"; then
        STRIPE_HTTP_CODE="000"
        STRIPE_BODY="$curl_output"
        STRIPE_REQUEST_ID=""
        rm -f "$header_file" "$body_file"
        return 1
    fi

    http_code="$(printf '%s' "$curl_output" | tail -n 1)"
    STRIPE_HTTP_CODE="$http_code"
    STRIPE_BODY="$(cat "$body_file")"
    STRIPE_REQUEST_ID="$(awk 'BEGIN { IGNORECASE=1 } /^Request-Id:/ { sub(/\r$/, "", $2); print $2; exit }' "$header_file")"
    rm -f "$header_file" "$body_file"
    return 0
}
