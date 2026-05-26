#!/usr/bin/env bash
# Live prod fail-closed contract: Stripe webhook rejects stale timestamp (HTTP 400).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/live_prod_reject_probe_lib.sh"

payload='{"id":"evt_contract_stale_ts","type":"invoice.payment_succeeded","data":{"object":{"id":"in_contract_stale_ts"}}}'
stale_ts="$(( $(date -u +%s) - 3600 ))"
response_path="$(live_prod_response_path "stripe_webhook_stale_timestamp_reject")"

capture_live_prod_response "$response_path" \
  -X POST "https://api.flapjack.foo/webhooks/stripe" \
  -H "content-type: application/json" \
  -H "stripe-signature: t=${stale_ts},v1=arbitrary_signature" \
  --data "$payload"

assert_status_code 400 "$response_path"
