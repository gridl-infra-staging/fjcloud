#!/usr/bin/env bash
#
# Configure the canonical Stripe Customer Portal configuration against a
# specific Stripe account, while keeping return_url ownership outside this
# script (owned by app/server session creation paths).
#
# Account selection (see docs/design/secret_sources.md#stripe-multi-account):
#   --account <name>     Resolve STRIPE_SECRET_KEY_<name> from env.
#                        Operators working with multiple Stripe accounts
#                        keep each account's key under a namespaced name
#                        in .secret/.env.secret (e.g. STRIPE_SECRET_KEY_flapjack_cloud).
#   (no flag)            Use canonical STRIPE_SECRET_KEY if set.
#
# Usage:
#   scripts/stripe/configure_billing_portal.sh --account flapjack_cloud
#   STRIPE_SECRET_KEY=sk_live_... scripts/stripe/configure_billing_portal.sh
#
# Output: machine-readable JSON describing account, configuration id, enabled
# portal features, and hosted-login/default-return facts from Stripe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/stripe_account.sh"

ACCOUNT_NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --account)
            ACCOUNT_NAME="$(stripe_account_require_flag_value "--account" "$#" "${2:-}")" || exit $?
            shift 2
            ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0;;
        *) echo "unknown argument: $1" >&2; exit 2;;
    esac
done

if stripe_account_resolve_secret_key "${ACCOUNT_NAME}"; then
    :
else
    exit $?
fi

log() { printf '%s\n' "$*" >&2; }

STRIPE_HTTP_CODE=""
STRIPE_BODY=""

stripe_request() {
    local method="$1"
    local path="$2"
    shift 2

    local header_file body_file curl_output
    header_file="$(mktemp)"
    body_file="$(mktemp)"

    if ! curl_output="$(curl -sS -D "$header_file" -o "$body_file" -w "%{http_code}" -K - -X "$method" "https://api.stripe.com$path" "$@" <<<"user = \"${STRIPE_SECRET_KEY}:\"" 2>&1)"; then
        STRIPE_HTTP_CODE="000"
        STRIPE_BODY="$curl_output"
        rm -f "$header_file" "$body_file"
        return 1
    fi

    STRIPE_HTTP_CODE="$(printf '%s' "$curl_output" | tail -n 1)"
    STRIPE_BODY="$(cat "$body_file")"
    rm -f "$header_file" "$body_file"
    return 0
}

require_http_success() {
    local step_name="$1"
    shift
    local expected_code
    for expected_code in "$@"; do
        if [ "${STRIPE_HTTP_CODE}" = "${expected_code}" ]; then
            return 0
        fi
    done

    log "ERROR: ${step_name} failed with HTTP ${STRIPE_HTTP_CODE}: ${STRIPE_BODY}"
    exit 1
}

PORTAL_FEATURE_ARGS=(
    -d "features[customer_update][enabled]=true"
    -d "features[customer_update][allowed_updates][]=address"
    -d "features[customer_update][allowed_updates][]=email"
    -d "features[customer_update][allowed_updates][]=name"
    -d "features[customer_update][allowed_updates][]=phone"
    -d "features[customer_update][allowed_updates][]=shipping"
    -d "features[customer_update][allowed_updates][]=tax_id"
    -d "features[invoice_history][enabled]=true"
    -d "features[payment_method_update][enabled]=true"
    -d "metadata[source]=scripts/stripe/configure_billing_portal.sh"
    -d "metadata[catalog_version]=2026-04-24"
)

log "== Stripe customer portal configuration =="
log "Active Stripe key prefix: ${STRIPE_SECRET_KEY:0:8}..."

if ! stripe_request GET "/v1/account"; then
    log "ERROR: Stripe account lookup failed: ${STRIPE_BODY}"
    exit 1
fi
require_http_success "account lookup" 200
ACCOUNT_ID="$(printf '%s' "$STRIPE_BODY" | jq -r '.id // empty')"
if [ -z "${ACCOUNT_ID}" ]; then
    log "ERROR: Stripe account lookup response did not include id"
    exit 1
fi

if ! stripe_request GET "/v1/billing_portal/configurations" -G --data-urlencode "active=true" --data-urlencode "limit=100"; then
    log "ERROR: Stripe portal configuration list failed: ${STRIPE_BODY}"
    exit 1
fi
require_http_success "configuration list" 200

DEFAULT_CONFIGURATION_ID="$(printf '%s' "$STRIPE_BODY" | jq -r '[.data[] | select(.is_default == true)] | sort_by(.created) | .[0].id // empty')"
CONFIGURATION_ACTION=""

if [ -n "${DEFAULT_CONFIGURATION_ID}" ]; then
    if ! stripe_request POST "/v1/billing_portal/configurations/${DEFAULT_CONFIGURATION_ID}" "${PORTAL_FEATURE_ARGS[@]}"; then
        log "ERROR: Stripe portal default-configuration update failed: ${STRIPE_BODY}"
        exit 1
    fi
    require_http_success "configuration update" 200
    CONFIGURATION_ACTION="updated_existing_default"
else
    if ! stripe_request POST "/v1/billing_portal/configurations" "${PORTAL_FEATURE_ARGS[@]}"; then
        log "ERROR: Stripe portal configuration create failed: ${STRIPE_BODY}"
        exit 1
    fi
    require_http_success "configuration create" 200
    CONFIGURATION_ACTION="created_new_default"
fi

CONFIGURATION_ID="$(printf '%s' "$STRIPE_BODY" | jq -r '.id // empty')"
if [ -z "${CONFIGURATION_ID}" ]; then
    log "ERROR: Stripe portal configuration response did not include id"
    exit 1
fi

IS_DEFAULT_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '.is_default // false')"
ENABLED_FEATURES_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '[.features | to_entries[]? | select(.value.enabled == true) | .key] | sort')"
HOSTED_LOGIN_ENABLED_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '.login_page.enabled // false')"
HOSTED_LOGIN_URL_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '.login_page.url // null')"
HOSTED_LOGIN_PRESENT_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '((.login_page.url // "") | length > 0)')"
DEFAULT_RETURN_URL_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '.default_return_url // null')"
DEFAULT_RETURN_PRESENT_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '((.default_return_url // "") | length > 0)')"

jq -nc \
    --arg target_account "${STRIPE_TARGET_ACCOUNT_NAME:-canonical}" \
    --arg account_id "${ACCOUNT_ID}" \
    --arg configuration_id "${CONFIGURATION_ID}" \
    --arg configuration_action "${CONFIGURATION_ACTION}" \
    --argjson is_default "${IS_DEFAULT_JSON}" \
    --argjson enabled_features "${ENABLED_FEATURES_JSON}" \
    --argjson hosted_login_enabled "${HOSTED_LOGIN_ENABLED_JSON}" \
    --argjson hosted_login_url "${HOSTED_LOGIN_URL_JSON}" \
    --argjson hosted_login_present "${HOSTED_LOGIN_PRESENT_JSON}" \
    --argjson default_return_url "${DEFAULT_RETURN_URL_JSON}" \
    --argjson default_return_url_present "${DEFAULT_RETURN_PRESENT_JSON}" \
    '{
      target_account:$target_account,
      account_id:$account_id,
      configuration_id:$configuration_id,
      configuration_action:$configuration_action,
      is_default:$is_default,
      enabled_features:$enabled_features,
      hosted_login:{
        enabled:$hosted_login_enabled,
        url:$hosted_login_url,
        present:$hosted_login_present
      },
      default_return_url:$default_return_url,
      default_return_url_present:$default_return_url_present
    }'
