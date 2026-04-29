#!/usr/bin/env bash
# hydrate_seeder_env_from_ssm.sh — print KEY=VALUE lines that satisfy the
# execute-contract env vars consumed by scripts/launch/seed_synthetic_traffic.sh.
#
# Resolves canonical SSM-owned values for the staging environment so an
# operator can do:
#
#   set -a; source .secret/.env.secret; set +a   # AWS credentials
#   source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)
#   bash scripts/launch/seed_synthetic_traffic.sh \
#     --tenant A --execute --i-know-this-hits-staging --duration-minutes 60
#
# This script ONLY produces the four required variables that come from SSM
# or are derived from SSM-owned values; FLAPJACK_API_KEY is intentionally
# NOT exported, because the seeder now resolves the per-node key per
# flapjack_url at call time (see node_api_key_for_url() in seed_synthetic_traffic.sh).

set -euo pipefail

ENVIRONMENT="${1:-staging}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

ssm_value() {
  aws ssm get-parameter --name "$1" --with-decryption --region "$REGION" \
    --query 'Parameter.Value' --output text 2>/dev/null
}

ADMIN_KEY="$(ssm_value "/fjcloud/${ENVIRONMENT}/admin_key")"
DATABASE_URL="$(ssm_value "/fjcloud/${ENVIRONMENT}/database_url")"
DNS_DOMAIN="$(ssm_value "/fjcloud/${ENVIRONMENT}/dns_domain")"

[ -n "$ADMIN_KEY" ] && [ "$ADMIN_KEY" != "None" ] || {
  echo "ERROR: failed to fetch /fjcloud/${ENVIRONMENT}/admin_key from SSM in ${REGION}" >&2
  exit 1
}
[ -n "$DATABASE_URL" ] && [ "$DATABASE_URL" != "None" ] || {
  echo "ERROR: failed to fetch /fjcloud/${ENVIRONMENT}/database_url from SSM in ${REGION}" >&2
  exit 1
}
[ -n "$DNS_DOMAIN" ] && [ "$DNS_DOMAIN" != "None" ] || {
  echo "ERROR: failed to fetch /fjcloud/${ENVIRONMENT}/dns_domain from SSM in ${REGION}" >&2
  exit 1
}

API_URL="https://api.${DNS_DOMAIN}"
# FLAPJACK_URL is the per-VM endpoint discovered/persisted by ensure_customer_and_tenant,
# but preflight_env still requires SOME value as a non-empty fallback before the mapping
# artifact exists. A default that points at the public API host is a safe placeholder
# because the seeder always re-resolves flapjack_url from the mapping artifact before
# any direct-node call. Use https://api.* so it parses as a valid URL.
FLAPJACK_URL="${FLAPJACK_URL:-https://api.${DNS_DOMAIN}}"

# Output as export KEY="value" lines for source <(...). Use printf %q for safe quoting.
printf 'export ADMIN_KEY=%q\n' "$ADMIN_KEY"
printf 'export DATABASE_URL=%q\n' "$DATABASE_URL"
printf 'export API_URL=%q\n' "$API_URL"
printf 'export FLAPJACK_URL=%q\n' "$FLAPJACK_URL"
