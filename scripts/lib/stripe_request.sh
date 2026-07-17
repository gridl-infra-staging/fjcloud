#!/usr/bin/env bash
# Shared Stripe request transport helper.
#
# Callers provide:
# - STRIPE_SECRET_KEY_EFFECTIVE
# - STRIPE_API_BASE
#
# Response contract:
# - stripe_request writes STRIPE_HTTP_CODE, STRIPE_BODY, and STRIPE_REQUEST_ID.

stripe_request_fail() {
    STRIPE_HTTP_CODE="000"
    STRIPE_BODY="$1"
    STRIPE_REQUEST_ID=""
    return 1
}

# Execute an authenticated Stripe API request and expose status, body, and request ID globals.
# TODO: Document stripe_request.
stripe_request() {
    local method="$1"
    local path="$2"
    shift 2

    local stripe_api_base="${STRIPE_API_BASE:-}"
    case "$stripe_api_base" in
        https://api.stripe.com|https://api.stripe.com/) ;;
        *)
            stripe_request_fail "STRIPE_API_BASE must be https://api.stripe.com."
            ;;
    esac
    case "$path" in
        /*) ;;
        *)
            stripe_request_fail "Stripe API path must start with '/'."
            ;;
    esac
    stripe_api_base="${stripe_api_base%/}"

    local stripe_secret_key="${STRIPE_SECRET_KEY_EFFECTIVE:-}"
    local header_file body_file http_code curl_output curl_user request_url
    if [ -z "$stripe_secret_key" ]; then
        stripe_request_fail "STRIPE_SECRET_KEY_EFFECTIVE is required."
    fi
    case "$stripe_secret_key" in
        *$'\n'*|*$'\r'*)
            stripe_request_fail "Stripe secret key contains unsupported newline characters."
            ;;
    esac
    header_file="$(mktemp)" || return 1
    body_file="$(mktemp)" || {
        rm -f "$header_file"
        return 1
    }
    curl_user="$(printf '%s:' "$stripe_secret_key" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    request_url="${stripe_api_base}${path}"

    # Keep the auth secret off disk by streaming curl config from stdin.
    if ! curl_output="$(printf 'user = "%s"\n' "$curl_user" | curl -sS -K - -D "$header_file" -o "$body_file" -w "%{http_code}" -X "$method" "$request_url" "$@" 2>&1)"; then
        rm -f "$header_file" "$body_file"
        stripe_request_fail "$curl_output"
    fi

    http_code="$(printf '%s' "$curl_output" | tail -n 1)"
    STRIPE_HTTP_CODE="$http_code"
    STRIPE_BODY="$(cat "$body_file")"
    STRIPE_REQUEST_ID="$(awk 'BEGIN { IGNORECASE=1 } /^Request-Id:/ { sub(/\r$/, "", $2); print $2; exit }' "$header_file")"
    rm -f "$header_file" "$body_file"
    return 0
}
