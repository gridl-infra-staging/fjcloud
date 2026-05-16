#!/usr/bin/env bash
# One-shot fixture capture. Run when the Cloudflare /zones/{id} response shape
# changes. Reads CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID_FLAPJACK_FOO from
# .env.secret. Sanitizes zone+account IDs to placeholders before writing.
set -euo pipefail
: "${CLOUDFLARE_API_TOKEN:?need CLOUDFLARE_API_TOKEN}"
: "${CLOUDFLARE_ZONE_ID_FLAPJACK_FOO:?need CLOUDFLARE_ZONE_ID_FLAPJACK_FOO}"
RAW=$(curl -sSf -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID_FLAPJACK_FOO}")
echo "$RAW" | jq --arg fakezone "TESTFIXTUREZONEID" --arg fakeacct "TESTFIXTUREACCT" '
  .result.id = $fakezone |
  .result.account.id = $fakeacct |
  .result.owner.id = $fakeacct
' > ops/scripts/tests/fixtures/cloudflare_zone_get_response.json
jq -e '.result.name == "flapjack.foo" and .result.plan.name == "Free Website"' \
  ops/scripts/tests/fixtures/cloudflare_zone_get_response.json \
  || { echo "ERROR: fixture must contain both result.name and plan.name to exercise the bug"; exit 1; }
echo "captured fixture at ops/scripts/tests/fixtures/cloudflare_zone_get_response.json"
