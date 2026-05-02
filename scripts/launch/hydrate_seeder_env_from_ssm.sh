#!/usr/bin/env bash
# hydrate_seeder_env_from_ssm.sh — print KEY=VALUE lines that satisfy the
# execute-contract env vars consumed by staging-targeted tooling.
#
# Despite the historical "seeder" name (kept for path stability), this is the
# canonical SSM hydrator for staging tooling subshells. Consumers include:
#   - scripts/launch/seed_synthetic_traffic.sh (synthetic traffic seeder)
#   - scripts/launch/run_full_backend_validation.sh (paid-beta-rc orchestrator)
#   - scripts/staging_billing_rehearsal.sh (credentialed billing rehearsal)
#   - scripts/canary/customer_loop_synthetic.sh (canary)
#   - scripts/validate_inbound_email_roundtrip.sh (ses_inbound RC step)
#
# Resolves canonical SSM-owned values for the staging environment so an
# operator can do:
#
#   set -a; source .secret/.env.secret; set +a   # AWS credentials
#   source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)
#   bash scripts/launch/seed_synthetic_traffic.sh \
#     --tenant A --execute --i-know-this-hits-staging --duration-minutes 60
#
# Or for the full RC:
#
#   source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)
#   bash scripts/launch/run_full_backend_validation.sh --paid-beta-rc <args>
#
# FLAPJACK_API_KEY is intentionally NOT exported because the seeder resolves
# the per-node key per flapjack_url at call time (see node_api_key_for_url()
# in seed_synthetic_traffic.sh).

set -euo pipefail

ENVIRONMENT="${1:-staging}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

ssm_value() {
  aws ssm get-parameter --name "$1" --with-decryption --region "$REGION" \
    --query 'Parameter.Value' --output text 2>/dev/null
}

# Fetch SSM-owned values. SSM is the canonical store: the deployed staging
# API process reads from these same SSM paths (via ops/scripts/lib/generate_ssm_env.sh
# which writes /etc/fjcloud/env). Hydrating from SSM keeps tooling subshells
# in sync with whatever the deployed API is actually using.
ADMIN_KEY="$(ssm_value "/fjcloud/${ENVIRONMENT}/admin_key")"
DATABASE_URL="$(ssm_value "/fjcloud/${ENVIRONMENT}/database_url")"
DNS_DOMAIN="$(ssm_value "/fjcloud/${ENVIRONMENT}/dns_domain")"
STRIPE_SECRET_KEY="$(ssm_value "/fjcloud/${ENVIRONMENT}/stripe_secret_key")"
SES_FROM_ADDRESS="$(ssm_value "/fjcloud/${ENVIRONMENT}/ses_from_address")"
STRIPE_WEBHOOK_SECRET="$(ssm_value "/fjcloud/${ENVIRONMENT}/stripe_webhook_secret")"

# Fail loudly on missing parameters. AWS CLI returns "None" when the
# parameter doesn't exist and `--query` finds no match; we reject both
# empty and "None" so a typo in the parameter path or a missing value
# doesn't silently propagate as an empty env var that the consumer
# misclassifies (e.g. staging_billing_rehearsal misclassified missing
# STAGING_STRIPE_WEBHOOK_URL as "dns_or_cloudflare_blocked").
require_value() {
  local name="$1" value="$2"
  if [ -z "$value" ] || [ "$value" = "None" ]; then
    echo "ERROR: failed to fetch /fjcloud/${ENVIRONMENT}/${name} from SSM in ${REGION}" >&2
    exit 1
  fi
}
require_value "admin_key" "$ADMIN_KEY"
require_value "database_url" "$DATABASE_URL"
require_value "dns_domain" "$DNS_DOMAIN"
require_value "stripe_secret_key" "$STRIPE_SECRET_KEY"
require_value "ses_from_address" "$SES_FROM_ADDRESS"
require_value "stripe_webhook_secret" "$STRIPE_WEBHOOK_SECRET"

API_URL="https://api.${DNS_DOMAIN}"

# FLAPJACK_URL is the per-VM endpoint discovered/persisted by ensure_customer_and_tenant,
# but preflight_env still requires SOME value as a non-empty fallback before the mapping
# artifact exists. A default that points at the public API host is a safe placeholder
# because the seeder always re-resolves flapjack_url from the mapping artifact before
# any direct-node call. Use https://api.* so it parses as a valid URL.
FLAPJACK_URL="${FLAPJACK_URL:-https://api.${DNS_DOMAIN}}"

# STAGING_API_URL and STAGING_STRIPE_WEBHOOK_URL are the contract env vars
# that scripts/staging_billing_dry_run.sh::validate_public_webhook_url expects.
# When STAGING_STRIPE_WEBHOOK_URL is missing the rehearsal records the failure
# under classification "dns_or_cloudflare_blocked" — a name that misleadingly
# reads as a network reachability issue. Hydrating from DNS_DOMAIN here keeps
# the contract correct without making the operator remember a separate URL.
STAGING_API_URL="${API_URL}"
STAGING_STRIPE_WEBHOOK_URL="${API_URL}/webhooks/stripe"

# Output as `export KEY=value` lines for `source <(...)`. Use printf %q for
# safe quoting (handles whitespace/special chars in any value).
#
# WHY STRIPE_SECRET_KEY is hydrated here (not inherited from the operator's
# .env.secret): each Stripe account has independent test mode. The staging
# API process reads its STRIPE_SECRET_KEY from this same SSM parameter
# (via generate_ssm_env.sh -> /etc/fjcloud/env), so any staging-targeted
# tooling MUST use the same key to find the customers/payment-methods/invoices
# the API created. If the operator's .env.secret has a sk_test_ key for a
# different Stripe account, attaching pm_card_visa to a customer created by
# the API returns "No such customer: cus_..." with HTTP 400 — the canary
# stripe_attach failure mode that surfaced 2026-05-01. By exporting
# STRIPE_SECRET_KEY from staging SSM here, the operator's stale .env.secret
# value is intentionally overridden in the staging-tooling subshell.
#
# WHY SES_FROM_ADDRESS is hydrated here: the RC ses_inbound step sends a
# probe email via `aws sesv2 send-email` from $SES_FROM_ADDRESS and asserts
# the receiving Authentication-Results header reports dkim/spf/dmarc=pass.
# DMARC alignment requires the From-header domain to be either SPF-aligned
# (Return-Path domain matches) or DKIM-aligned (signing d= domain matches).
# When the operator's shell has a personal-domain SES_FROM_ADDRESS (e.g.
# bitts90@gmail.com), neither SES nor flapjack.foo can satisfy gmail.com's
# DMARC policy and the probe fails with "Authentication-Results failed for:
# dmarc=fail" — observed in 20260501T024619Z_post_envisolation_fix RC run.
# system@flapjack.foo is the canonical sender (DKIM-verified, SPF includes
# amazonses.com) and passes DMARC end-to-end (Apr 28 evidence proved it).
#
# WHY STRIPE_WEBHOOK_SECRET is hydrated here: scripts/staging_billing_dry_run.sh
# requires it via require_nonempty_env. Without it the rehearsal early-exits
# at validate_runtime_stripe_webhook_secret. Like STRIPE_SECRET_KEY, it must
# match the value the deployed API uses to verify webhook signatures.
printf 'export ADMIN_KEY=%q\n' "$ADMIN_KEY"
printf 'export DATABASE_URL=%q\n' "$DATABASE_URL"
printf 'export API_URL=%q\n' "$API_URL"
printf 'export FLAPJACK_URL=%q\n' "$FLAPJACK_URL"
printf 'export STRIPE_SECRET_KEY=%q\n' "$STRIPE_SECRET_KEY"
printf 'export SES_FROM_ADDRESS=%q\n' "$SES_FROM_ADDRESS"
printf 'export STRIPE_WEBHOOK_SECRET=%q\n' "$STRIPE_WEBHOOK_SECRET"
printf 'export STAGING_API_URL=%q\n' "$STAGING_API_URL"
printf 'export STAGING_STRIPE_WEBHOOK_URL=%q\n' "$STAGING_STRIPE_WEBHOOK_URL"
