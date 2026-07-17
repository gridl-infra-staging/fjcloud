#!/usr/bin/env bash
# Live prod fail-closed contract: Stripe webhook rejects bad signature (HTTP 400).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/live_prod_reject_probe_lib.sh"

payload='{"id":"evt_contract_bad_sig","type":"invoice.payment_succeeded","data":{"object":{"id":"in_contract_bad_sig"}}}'
current_ts="$(date -u +%s)"
response_path="$(live_prod_response_path "stripe_webhook_bad_signature_reject")"

capture_live_prod_response "$response_path" \
  -X POST "https://api.flapjack.foo/webhooks/stripe" \
  -H "content-type: application/json" \
  -H "stripe-signature: t=${current_ts},v1=invalid_signature_value" \
  --data "$payload"

assert_status_code 400 "$response_path"
