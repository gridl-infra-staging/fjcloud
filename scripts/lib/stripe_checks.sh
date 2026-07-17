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
#   check_stripe_account_status    — Pure parser of a GET /v1/account body: emits
#                                    payout/charge readiness booleans + requirement counts
#   check_stripe_webhook_secret_present — STRIPE_WEBHOOK_SECRET is set with whsec_ prefix
#   check_stripe_webhook_forwarding     — `stripe listen` process is running
#
# REASON: codes:
#   stripe_key_unset                STRIPE_SECRET_KEY missing (alias fallback allowed)
#   stripe_key_bad_prefix           Effective Stripe key does not start with sk_test_ or rk_test_
#   stripe_api_timeout              Stripe API call timed out (connect or overall)
#   stripe_auth_failed              Stripe returned authentication_error for key
#   stripe_key_http_error           Stripe key live check returned non-200 HTTP
#   stripe_account_not_ready        Account not fully payout-ready (charges/payouts/details
#                                   not all enabled, or outstanding requirements/disabled_reason)
#   stripe_account_parse_error      GET /v1/account body could not be parsed as JSON
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
# shellcheck disable=SC1091
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
# stripe_live_cutover_enabled
# Returns success only when STRIPE_LIVE_CUTOVER is explicitly set to literal 1.
# --------------------------------------------------------------------------
stripe_live_cutover_enabled() {
    [ "${STRIPE_LIVE_CUTOVER:-}" = "1" ]
}

# --------------------------------------------------------------------------
# stripe_secret_key_has_allowed_prefix
# Returns success when key has a permitted Stripe secret prefix.
# Test-mode prefixes are always allowed; live-mode prefixes require explicit
# STRIPE_LIVE_CUTOVER=1 opt-in.
# --------------------------------------------------------------------------
stripe_secret_key_has_allowed_prefix() {
    local key="$1"
    if [[ "$key" == sk_test_* || "$key" == rk_test_* ]]; then
        return 0
    fi

    if stripe_live_cutover_enabled && [[ "$key" == sk_live_* || "$key" == rk_live_* ]]; then
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

    if ! stripe_secret_key_has_allowed_prefix "$key"; then
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
    if ! stripe_secret_key_has_allowed_prefix "$key"; then
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
# check_stripe_account_status
# Pure parser of a Stripe GET /v1/account JSON body. Performs NO network call —
# the caller (e.g. scripts/probe_live_state.sh) fetches the body once and passes
# it in. Emits only booleans and counts so the result is safe to record in a
# public-mirror-adjacent receipt and is KAT-testable from fixtures:
#   charges_enabled=<true|false>
#   payouts_enabled=<true|false>
#   details_submitted=<true|false>
#   currently_due_count=<N>
#   past_due_count=<N>
#   disabled_reason_present=<true|false>
# Never emits account id, email, or the raw disabled_reason string.
#
# Returns 0 when the account is fully payout-ready (all three booleans true, no
# currently_due/past_due requirements, no disabled_reason). Otherwise emits
# REASON: stripe_account_not_ready and fails/skips per live-gate semantics.
# --------------------------------------------------------------------------
check_stripe_account_status() {
    local body="$1"

    if ! command -v python3 >/dev/null 2>&1; then
        live_gate_fail_with_reason "stripe_account_parse_error" "python3 required to parse Stripe account status"
        return 1
    fi

    local parsed py_status=0
    parsed="$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(d, dict):
    sys.exit(2)
def b(v):
    return "true" if v else "false"
charges = bool(d.get("charges_enabled"))
payouts = bool(d.get("payouts_enabled"))
details = bool(d.get("details_submitted"))
req = d.get("requirements") or {}
currently_due = req.get("currently_due") or []
past_due = req.get("past_due") or []
disabled_reason = req.get("disabled_reason")
print("charges_enabled=" + b(charges))
print("payouts_enabled=" + b(payouts))
print("details_submitted=" + b(details))
print("currently_due_count=" + str(len(currently_due)))
print("past_due_count=" + str(len(past_due)))
print("disabled_reason_present=" + b(disabled_reason is not None))
ready = charges and payouts and details and not currently_due and not past_due and disabled_reason is None
sys.exit(0 if ready else 3)
')" || py_status=$?

    if [ "$py_status" -eq 2 ]; then
        live_gate_fail_with_reason "stripe_account_parse_error" "Stripe GET /v1/account body was not valid JSON"
        return 1
    fi

    printf '%s\n' "$parsed"

    if [ "$py_status" -eq 0 ]; then
        return 0
    fi

    live_gate_fail_with_reason "stripe_account_not_ready" "Stripe account is not fully ready for live payouts"
    return 1
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
