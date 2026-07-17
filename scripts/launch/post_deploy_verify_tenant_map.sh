#!/usr/bin/env bash
# post_deploy_verify_tenant_map.sh — confirm the deployed staging API
# picks up the tenant-map URL fallback from infra/api/src/routes/internal.rs.
#
# Usage:
#   bash scripts/launch/post_deploy_verify_tenant_map.sh
#
# Pre-conditions:
#   - .secret/.env.secret already sourced (AWS creds present)
#   - hydrate_seeder_env_from_ssm.sh has set ADMIN_KEY / API_URL etc.
#
# Output: prints the deployed flapjack_url for tenant A and exits 0 if
# non-null, exits 1 otherwise. The non-null assertion is the proof
# that commit 019bc5b9 (tenant-map URL fallback to vm_inventory) is
# live; it is the gate downstream of which usage_records can finally
# populate for synthetic Tenant A.

set -euo pipefail

CUSTOMER_ID="${TENANT_A_CUSTOMER_ID:-0a65f0b7-14b3-4e08-acf6-2222a02c7858}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

if [ -z "${API_URL:-}" ]; then
  echo "ERROR: API_URL is not set. Source .secret/.env.secret and eval scripts/launch/hydrate_seeder_env_from_ssm.sh staging first." >&2
  exit 64
fi

INTERNAL_TOKEN="$(aws ssm get-parameter \
  --name "/fjcloud/staging/internal_auth_token" \
  --with-decryption --region "$REGION" \
  --query "Parameter.Value" --output text 2>/dev/null)"

if [ -z "$INTERNAL_TOKEN" ] || [ "$INTERNAL_TOKEN" = "None" ]; then
  echo "ERROR: failed to fetch /fjcloud/staging/internal_auth_token from SSM" >&2
  exit 1
fi

response="$(curl -fsSL "${API_URL}/internal/tenant-map" \
  -H "x-internal-key: ${INTERNAL_TOKEN}" 2>/dev/null)"

if [ -z "$response" ]; then
  echo "ERROR: /internal/tenant-map returned no payload" >&2
  exit 1
fi

flapjack_url="$(printf '%s' "$response" | python3 -c "
import sys, json
payload = json.load(sys.stdin)
for tenant in payload:
    if tenant.get('customer_id') == '${CUSTOMER_ID}':
        url = tenant.get('flapjack_url')
        if url is None:
            print('NULL')
        else:
            print(url)
        break
else:
    print('NOT_FOUND')
")"

case "$flapjack_url" in
  NULL)
    echo "FAIL: tenant-map flapjack_url for tenant A (${CUSTOMER_ID}) is still null." >&2
    echo "      This means the deployed staging API has NOT picked up the" >&2
    echo "      tenant-map URL fallback from commit 019bc5b9. Check the" >&2
    echo "      currently-deployed sha:" >&2
    echo "        aws ssm get-parameter --name /fjcloud/staging/last_deploy_sha" >&2
    exit 1
    ;;
  NOT_FOUND)
    echo "FAIL: tenant A (${CUSTOMER_ID}) is missing from /internal/tenant-map." >&2
    exit 1
    ;;
  *)
    echo "OK: tenant-map flapjack_url for tenant A is live: ${flapjack_url}"
    exit 0
    ;;
esac
