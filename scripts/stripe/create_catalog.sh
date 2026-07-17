#!/usr/bin/env bash
#
# Create the canonical Flapjack Stripe product catalog against a specific
# Stripe account. Idempotent: skips creation if a product with matching
# metadata[rate_card_dimension] already exists as active on that account.
#
# Account selection (see docs/design/secret_sources.md#stripe-multi-account):
#   --account <name>     Resolve STRIPE_SECRET_KEY_<name> from env.
#                        Operators working with multiple Stripe accounts
#                        keep each account's key under a namespaced name
#                        in .secret/.env.secret (e.g. STRIPE_SECRET_KEY_flapjack_cloud).
#   (no flag)            Use canonical STRIPE_SECRET_KEY if set.
#
# Usage:
#   scripts/stripe/create_catalog.sh --account flapjack_cloud
#   STRIPE_SECRET_KEY=sk_test_... scripts/stripe/create_catalog.sh
#
# Output: machine-readable JSON to stdout summarizing created/existing IDs.

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
api() { curl -sS -u "${STRIPE_SECRET_KEY}:" "$@"; }

# Dimensions:
#   dim_key | product_name                | type      | unit_amount | unit_amount_decimal | currency | interval
CATALOG=(
  "storage_rate_per_mb_month|Flapjack Hot Storage|one_time|5||usd|"
  "cold_storage_rate_per_gb_month|Flapjack Cold Storage|one_time|2||usd|"
  "object_storage_rate_per_gb_month|Flapjack Object Storage|one_time|||usd|"
  "object_storage_egress_rate_per_gb|Flapjack Object Egress|one_time|1||usd|"
  "shared_minimum_spend_cents|Flapjack Shared Minimum|recurring|500||usd|month"
  "minimum_spend_cents|Flapjack Dedicated Minimum|recurring|1000||usd|month"
)

# Object storage = $0.024/GB-month → 2.4 cents. Use unit_amount_decimal.
# Inject separately since bash arrays don't handle empty fields cleanly.
OBJECT_STORAGE_DECIMAL="2.4"

summary_entries=()

find_existing_product() {
  # Use the list endpoint + local metadata filter instead of /search. The /search
  # endpoint has an indexing lag (seconds to minutes) that makes immediate
  # idempotency unreliable for a just-created object.
  local dim="$1"
  api -G "https://api.stripe.com/v1/products" \
    --data-urlencode "limit=100" \
    --data-urlencode "active=true" \
    | jq -r --arg dim "${dim}" \
        '[.data[] | select(.metadata.rate_card_dimension == $dim)] | sort_by(.created) | .[0].id // empty'
}

find_existing_price() {
  local product_id="$1"
  api -G "https://api.stripe.com/v1/prices" \
    --data-urlencode "product=${product_id}" \
    --data-urlencode "active=true" \
    --data-urlencode "limit=10" \
    | jq -r '.data[0].id // empty'
}

create_product() {
  local dim="$1" name="$2"
  api -X POST "https://api.stripe.com/v1/products" \
    -d "name=${name}" \
    -d "metadata[rate_card_dimension]=${dim}" \
    -d "metadata[catalog_version]=2026-04-24" \
    -d "metadata[source]=scripts/stripe/create_catalog.sh" \
    | jq -r '.id'
}

create_price() {
  local product_id="$1" dim="$2" type="$3" unit_amount="$4" unit_amount_decimal="$5" currency="$6" interval="$7"
  local args=(-X POST "https://api.stripe.com/v1/prices"
              -d "product=${product_id}"
              -d "currency=${currency}"
              -d "metadata[rate_card_dimension]=${dim}")
  if [[ -n "${unit_amount_decimal}" ]]; then
    args+=(-d "unit_amount_decimal=${unit_amount_decimal}")
  else
    args+=(-d "unit_amount=${unit_amount}")
  fi
  if [[ "${type}" == "recurring" ]]; then
    args+=(-d "recurring[interval]=${interval}"
           -d "recurring[usage_type]=licensed")
  fi
  api "${args[@]}" | jq -r '.id'
}

log "== Flapjack Stripe catalog creation =="
log "Active Stripe key prefix: ${STRIPE_SECRET_KEY:0:8}..."
account_id=$(api https://api.stripe.com/v1/account | jq -r '.id')
log "Active account: ${account_id}"
log ""

for entry in "${CATALOG[@]}"; do
  IFS='|' read -r dim name type unit_amount unit_amount_decimal currency interval <<<"${entry}"
  if [[ "${dim}" == "object_storage_rate_per_gb_month" ]]; then
    unit_amount_decimal="${OBJECT_STORAGE_DECIMAL}"
    unit_amount=""
  fi

  log "-- ${dim} (${name}) --"

  product_id="$(find_existing_product "${dim}")"
  product_created="false"
  if [[ -z "${product_id}" ]]; then
    product_id="$(create_product "${dim}" "${name}")"
    product_created="true"
    log "  created product: ${product_id}"
  else
    log "  existing product: ${product_id}"
  fi

  price_id="$(find_existing_price "${product_id}")"
  price_created="false"
  if [[ -z "${price_id}" ]]; then
    price_id="$(create_price "${product_id}" "${dim}" "${type}" "${unit_amount}" "${unit_amount_decimal}" "${currency}" "${interval}")"
    price_created="true"
    log "  created price:   ${price_id}"
  else
    log "  existing price:  ${price_id}"
  fi

  summary_entries+=("$(jq -nc \
    --arg dim "${dim}" \
    --arg name "${name}" \
    --arg product_id "${product_id}" \
    --arg price_id "${price_id}" \
    --arg type "${type}" \
    --arg unit_amount "${unit_amount}" \
    --arg unit_amount_decimal "${unit_amount_decimal}" \
    --argjson product_created "${product_created}" \
    --argjson price_created "${price_created}" \
    '{dimension:$dim, name:$name, product_id:$product_id, price_id:$price_id, price_type:$type, unit_amount:$unit_amount, unit_amount_decimal:$unit_amount_decimal, product_created:$product_created, price_created:$price_created}')")
done

log ""
log "== Done. Summary: =="

jq -nc \
  --arg account_id "${account_id}" \
  --arg key_prefix "${STRIPE_SECRET_KEY:0:8}" \
  --slurpfile entries <(printf '%s\n' "${summary_entries[@]}" | jq -s '.') \
  '{account_id:$account_id, key_prefix:$key_prefix, entries:$entries[0]}'
