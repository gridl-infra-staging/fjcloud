#!/usr/bin/env bash
# Stripe validation checks for the backend launch gate.
#
# Each check function uses live_gate_require to enforce preconditions:
#   - Gate ON  (BACKEND_LIVE_GATE=1): failure = exit 1 (hard block)
#   - Gate OFF: failure = [skip] message + continue
#
# Functions:
#   resolve_stripe_secret_key      — resolves effective key (canonical first, alias fallback)
#   check_stripe_key_present       — effective key is set with sk_test_ or rk_test_ prefix
#   check_stripe_key_live          — Key authenticates against Stripe GET /v1/balance
#   check_stripe_webhook_secret_present — STRIPE_WEBHOOK_SECRET is set with whsec_ prefix
#   check_stripe_webhook_forwarding     — `stripe listen` process is running
#
# REASON: codes:
#   stripe_key_unset                STRIPE_SECRET_KEY missing (alias fallback allowed)
#   stripe_key_bad_prefix           Effective Stripe key does not start with sk_test_ or rk_test_
#   stripe_api_timeout              Stripe API call timed out (connect or overall)
#   stripe_auth_failed              Stripe returned authentication_error for key
#   stripe_key_http_error           Stripe key live check returned non-200 HTTP
#   stripe_webhook_secret_unset     STRIPE_WEBHOOK_SECRET missing
#   stripe_webhook_secret_bad_prefix STRIPE_WEBHOOK_SECRET does not start with whsec_
#   stripe_listen_not_running       No running "stripe listen" process

set -euo pipefail

STRIPE_CHECKS_SCRIPT_PATH="${BASH_SOURCE[0]}"
STRIPE_CHECKS_DIR="${STRIPE_CHECKS_SCRIPT_PATH%/*}"
if [ "$STRIPE_CHECKS_DIR" = "$STRIPE_CHECKS_SCRIPT_PATH" ]; then
    STRIPE_CHECKS_DIR="."
fi
STRIPE_CHECKS_DIR="$(cd "$STRIPE_CHECKS_DIR" && pwd)"
source "$STRIPE_CHECKS_DIR/live_gate.sh"

# --------------------------------------------------------------------------
# resolve_stripe_secret_key
# Emits the effective key to stdout for capture by callers.
# Prefers STRIPE_SECRET_KEY and falls back to STRIPE_TEST_SECRET_KEY only
# when STRIPE_SECRET_KEY is unset.
# --------------------------------------------------------------------------
resolve_stripe_secret_key() {
    if [ "${STRIPE_SECRET_KEY+x}" = "x" ]; then
        if [ -n "$STRIPE_SECRET_KEY" ]; then
            printf '%s\n' "${STRIPE_SECRET_KEY}"
            return 0
        fi

        return 1
    fi

    if [ -n "${STRIPE_TEST_SECRET_KEY:-}" ]; then
        printf '%s\n' "${STRIPE_TEST_SECRET_KEY}"
        return 0
    fi

    return 1
}

# --------------------------------------------------------------------------
# check_stripe_key_present
# Validates that the resolved Stripe secret key is set and has sk_test_ or
# rk_test_ prefix.
# --------------------------------------------------------------------------
check_stripe_key_present() {
    local key
    if ! key="$(resolve_stripe_secret_key)"; then
        live_gate_fail_with_reason "stripe_key_unset" "STRIPE_SECRET_KEY is not set"
        return 0
    fi

    if [[ "$key" != sk_test_* && "$key" != rk_test_* ]]; then
        live_gate_fail_with_reason "stripe_key_bad_prefix" "STRIPE_SECRET_KEY must start with sk_test_ or rk_test_ (sk_live_ and rk_live_ keys are not allowed)"
        return 0
    fi
}

# --------------------------------------------------------------------------
# stripe_curl_user_config
# Emits curl config content on stdout so Stripe secrets never appear in the
# process argv while still using curl's supported auth configuration.
# --------------------------------------------------------------------------
stripe_curl_user_config() {
    local key="$1"
    local escaped_key="$key"
    escaped_key="${escaped_key//\\/\\\\}"
    escaped_key="${escaped_key//\"/\\\"}"
    printf 'user = "%s:"\n' "$escaped_key"
}

# --------------------------------------------------------------------------
# check_stripe_key_live
# Calls Stripe GET /v1/balance to verify the key actually authenticates.
# Fails on HTTP error or authentication_error in the response body.
# --------------------------------------------------------------------------
check_stripe_key_live() {
    local key
    if ! key="$(resolve_stripe_secret_key)"; then
        live_gate_fail_with_reason "stripe_key_unset" "STRIPE_SECRET_KEY is not set (cannot perform live check)"
        return 0
    fi

    # Defensive validation for direct invocations that skip check_stripe_key_present.
    if [[ "$key" != sk_test_* && "$key" != rk_test_* ]]; then
        live_gate_fail_with_reason "stripe_key_bad_prefix" "STRIPE_SECRET_KEY must start with sk_test_ or rk_test_ (sk_live_ and rk_live_ keys are not allowed)"
        return 0
    fi

    local response http_code curl_exit=0
    if response="$(curl -s \
        --config <(stripe_curl_user_config "$key") \
        --max-time "${GATE_INNER_TIMEOUT_SEC:-10}" \
        --connect-timeout "${GATE_INNER_TIMEOUT_SEC:-10}" \
        -w "\n%{http_code}" \
        "https://api.stripe.com/v1/balance" 2>&1)"; then
        curl_exit=0
    else
        curl_exit=$?
    fi

    if [ "$curl_exit" -eq 28 ]; then
        echo "REASON: stripe_api_timeout" >&2
        exit 124
    fi

    if [ "$curl_exit" -ne 0 ]; then
        live_gate_fail_with_reason "stripe_key_http_error" \
            "Stripe GET /v1/balance failed before HTTP response (curl exit $curl_exit)"
        return 0
    fi

    # Extract HTTP status code (last line) and body (everything before)
    http_code="$(echo "$response" | tail -1)"
    local body
    body="$(echo "$response" | sed '$d')"

    # Check for authentication errors in the response body
    if echo "$body" | grep -q '"authentication_error"'; then
        live_gate_fail_with_reason "stripe_auth_failed" \
            "Stripe API authentication failed — key may be revoked or invalid"
        return 0
    fi

    # Check HTTP status code
    if [ "$http_code" != "200" ]; then
        live_gate_fail_with_reason "stripe_key_http_error" \
            "Stripe GET /v1/balance returned HTTP $http_code — expected 200"
        return 0
    fi
}

# --------------------------------------------------------------------------
# check_stripe_webhook_secret_present
# Validates STRIPE_WEBHOOK_SECRET is set and has the whsec_ prefix.
# --------------------------------------------------------------------------
check_stripe_webhook_secret_present() {
    if [ -z "${STRIPE_WEBHOOK_SECRET:-}" ]; then
        live_gate_fail_with_reason "stripe_webhook_secret_unset" "STRIPE_WEBHOOK_SECRET is not set"
        return 0
    fi

    if [[ "${STRIPE_WEBHOOK_SECRET:-}" != whsec_* ]]; then
        live_gate_fail_with_reason "stripe_webhook_secret_bad_prefix" "STRIPE_WEBHOOK_SECRET does not start with whsec_ prefix"
        return 0
    fi
}

# --------------------------------------------------------------------------
# stripe_webhook_forward_to
# Builds the webhook URL operators should use with `stripe listen --forward-to`.
# Prefers an explicit override, then runtime API hints, then local-dev defaults.
# --------------------------------------------------------------------------
stripe_webhook_forward_to() {
    if [ -n "${STRIPE_WEBHOOK_FORWARD_TO:-}" ]; then
        printf '%s\n' "${STRIPE_WEBHOOK_FORWARD_TO}"
        return 0
    fi

    if [ -n "${API_URL:-}" ]; then
        printf '%s/webhooks/stripe\n' "${API_URL%/}"
        return 0
    fi

    if [ -n "${LISTEN_ADDR:-}" ]; then
        local listen_addr="${LISTEN_ADDR}"
        local host port

        if [[ "$listen_addr" == *"://"* ]]; then
            listen_addr="${listen_addr#*://}"
            listen_addr="${listen_addr%%/*}"
        fi

        port="${listen_addr##*:}"
        if [[ "$listen_addr" == \[* ]]; then
            host="${listen_addr%%]*}"
            host="${host#[}"
        else
            host="${listen_addr%:*}"
        fi

        case "$host" in
            ""|"0.0.0.0"|"::"|"[::]")
                host="localhost"
                ;;
        esac

        printf 'http://%s:%s/webhooks/stripe\n' "$host" "$port"
        return 0
    fi

    printf 'http://localhost:%s/webhooks/stripe\n' "${API_PORT:-3001}"
}

# --------------------------------------------------------------------------
# check_stripe_webhook_forwarding
# Checks that a `stripe listen` process is running (via pgrep).
# --------------------------------------------------------------------------
check_stripe_webhook_forwarding() {
    if ! pgrep -f "stripe listen" >/dev/null 2>&1; then
        local forward_to
        forward_to="$(stripe_webhook_forward_to)"
        live_gate_fail_with_reason "stripe_listen_not_running" \
            "No 'stripe listen' process detected — run: stripe listen --forward-to ${forward_to}"
        return 0
    fi
}
