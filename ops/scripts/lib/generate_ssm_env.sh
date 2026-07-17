#!/usr/bin/env bash
# generate_ssm_env.sh — Read SSM parameters and write runtime env files.
#
# Single source of truth for the SSM-param-name -> env-var-name mapping.
# Called on-instance before service restart to populate the EnvironmentFile
# contracts referenced by systemd units:
#   - /etc/fjcloud/env            (fjcloud-api, fjcloud-aggregation-job)
#   - /etc/fjcloud/metering-env   (fj-metering-agent)
#
# Usage: generate_ssm_env.sh <env>
#   env: staging | prod
#
# Requires: aws CLI with IAM role that can ssm:GetParametersByPath + kms:Decrypt.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: generate_ssm_env.sh <env>"
  exit 1
fi

ENV="$1"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
SSM_PREFIX="/fjcloud/${ENV}"
ENV_FILE="${FJCLOUD_ENV_FILE:-/etc/fjcloud/env}"
METERING_ENV_FILE="${FJCLOUD_METERING_ENV_FILE:-/etc/fjcloud/metering-env}"

if [[ "$ENV" != "staging" && "$ENV" != "prod" ]]; then
  echo "ERROR: env must be 'staging' or 'prod' (got: ${ENV})"
  exit 1
fi

# ---------------------------------------------------------------------------
# SSM param name -> env var name mapping
#
# Bash 3.2 compatibility note: keep this as a case statement (not
# associative arrays) so macOS default bash can execute this script.
# Keys are the SSM parameter suffix (after /fjcloud/<env>/).
# Values are the env var names that infra/api/src/config.rs::from_reader and
# infra/api/src/startup_env.rs::StartupEnvSnapshot expect.
# Parameters NOT in this map are skipped (e.g., last_deploy_sha, db_password).
# ---------------------------------------------------------------------------

map_ssm_suffix_to_env_var() {
  local suffix="$1"
  case "$suffix" in
    # Required by config.rs::from_reader
    database_url) echo "DATABASE_URL" ;;
    jwt_secret) echo "JWT_SECRET" ;;
    admin_key) echo "ADMIN_KEY" ;;

    # Shared-VM provisioning — infra/api/src/provisioner/aws.rs
    aws_ami_id) echo "AWS_AMI_ID" ;;
    aws_subnet_id) echo "AWS_SUBNET_ID" ;;
    aws_security_group_ids) echo "AWS_SECURITY_GROUP_IDS" ;;
    aws_key_pair_name) echo "AWS_KEY_PAIR_NAME" ;;
    aws_instance_profile_name) echo "AWS_INSTANCE_PROFILE_NAME" ;;

    # Shared-VM DNS routing — infra/api/src/startup.rs::init_dns_manager
    cloudflare_api_token) echo "CLOUDFLARE_API_TOKEN" ;;
    cloudflare_zone_id) echo "CLOUDFLARE_ZONE_ID" ;;
    dns_domain) echo "DNS_DOMAIN" ;;

    # Stripe — config.rs::from_reader (optional until Stage 7 activates them)
    stripe_secret_key) echo "STRIPE_SECRET_KEY" ;;
    stripe_publishable_key) echo "STRIPE_PUBLISHABLE_KEY" ;;
    stripe_webhook_secret) echo "STRIPE_WEBHOOK_SECRET" ;;
    stripe_success_url) echo "STRIPE_SUCCESS_URL" ;;
    stripe_cancel_url) echo "STRIPE_CANCEL_URL" ;;

    # Cold storage — startup_env.rs
    cold_bucket_name) echo "COLD_STORAGE_BUCKET" ;;
    cold_storage_prefix) echo "COLD_STORAGE_PREFIX" ;;
    cold_storage_region) echo "COLD_STORAGE_REGION" ;;
    cold_storage_endpoint) echo "COLD_STORAGE_ENDPOINT" ;;
    cold_storage_regions) echo "COLD_STORAGE_REGIONS" ;;

    # Storage encryption — startup_env.rs
    storage_encryption_key) echo "STORAGE_ENCRYPTION_KEY" ;;

    # SES email — startup_env.rs
    ses_from_address) echo "SES_FROM_ADDRESS" ;;
    ses_region) echo "SES_REGION" ;;
    ses_configuration_set) echo "SES_CONFIGURATION_SET" ;;

    # Internal auth — config.rs::from_reader
    internal_auth_token) echo "INTERNAL_AUTH_TOKEN" ;;

    # Browser proof/runtime throttles — router.rs and tenant_quota.rs.
    # These are deliberately SSM-owned so staging can run deployed E2E
    # proofs without hand-editing /etc/fjcloud/env on every deploy.
    tenant_rate_limit_rpm) echo "TENANT_RATE_LIMIT_RPM" ;;
    default_max_query_rps) echo "DEFAULT_MAX_QUERY_RPS" ;;
    default_max_write_rps) echo "DEFAULT_MAX_WRITE_RPS" ;;

    # Alert webhook URLs — read by infra/api/src/startup.rs::init_alert_service.
    slack_webhook_url) echo "SLACK_WEBHOOK_URL" ;;
    discord_webhook_url) echo "DISCORD_WEBHOOK_URL" ;;

    # OAuth providers — config.rs::from_reader (GOOGLE/GITHUB_OAUTH_CLIENT_*).
    # Each provider is enabled only when both id+secret resolve; absent => the
    # /auth/oauth/<provider>/start route returns 501. APP_BASE_URL drives the
    # callback redirect_uri in main.rs::build_oauth_runtime_config — staging must
    # set it to its own host or callbacks route to the prod web host.
    google_oauth_client_id) echo "GOOGLE_OAUTH_CLIENT_ID" ;;
    google_oauth_client_secret) echo "GOOGLE_OAUTH_CLIENT_SECRET" ;;
    github_oauth_client_id) echo "GITHUB_OAUTH_CLIENT_ID" ;;
    github_oauth_client_secret) echo "GITHUB_OAUTH_CLIENT_SECRET" ;;
    app_base_url) echo "APP_BASE_URL" ;;

    # Algolia migration runtime admission — config.rs::from_reader.
    algolia_migration_enabled) echo "FJCLOUD_ALGOLIA_MIGRATION_ENABLED" ;;
    *) return 1 ;;
  esac
}

set_resolved_value() {
  local key="$1"
  local value="$2"
  local slot="RESOLVED_${key}"
  printf -v "$slot" '%s' "$value"
}

get_resolved_value() {
  local key="$1"
  local slot="RESOLVED_${key}"
  eval "printf '%s' \"\${${slot}:-}\""
}

assert_envfile_safe_value() {
  local key="$1"
  local value="$2"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "ERROR: ${key} contains newline bytes and cannot be written safely to an EnvironmentFile" >&2
    exit 1
  fi
}

append_envfile_line() {
  local file="$1"
  local key="$2"
  local value="$3"
  assert_envfile_safe_value "$key" "$value"
  printf '%s\n' "${key}=${value}" >> "$file"
}

STATIC_VAR_COUNT=2

# ---------------------------------------------------------------------------
# Fetch SSM parameters
# ---------------------------------------------------------------------------

echo "==> Fetching SSM parameters from ${SSM_PREFIX}/"

SSM_OUTPUT=$(aws ssm get-parameters-by-path \
  --path "${SSM_PREFIX}/" \
  --with-decryption \
  --region "$REGION" \
  --output json)

if [[ -z "$SSM_OUTPUT" ]]; then
  echo "ERROR: Failed to fetch SSM parameters from ${SSM_PREFIX}/"
  exit 1
fi

# ---------------------------------------------------------------------------
# Write /etc/fjcloud/env atomically
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "$ENV_FILE")"

TMPFILE=$(mktemp "${ENV_FILE}.XXXXXX")

{
  printf '%s\n' "# Generated by generate_ssm_env.sh — do not edit manually"
  printf '%s\n' "# Environment: ${ENV}"
  printf '%s\n' "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""

  # Static vars first
  set_resolved_value "ENVIRONMENT" "$ENV"
  set_resolved_value "NODE_SECRET_BACKEND" "ssm"
  append_envfile_line "$TMPFILE" "ENVIRONMENT" "$ENV"
  append_envfile_line "$TMPFILE" "NODE_SECRET_BACKEND" "ssm"
} > "$TMPFILE"

# SSM-sourced vars
MAPPED_COUNT=0
SKIPPED_LIST=()

while IFS= read -r -d '' param_name && IFS= read -r -d '' param_value; do
  # Extract suffix after /fjcloud/<env>/
  suffix="${param_name#${SSM_PREFIX}/}"

  if env_var="$(map_ssm_suffix_to_env_var "$suffix")"; then
    set_resolved_value "$env_var" "$param_value"
    append_envfile_line "$TMPFILE" "$env_var" "$param_value"
    MAPPED_COUNT=$((MAPPED_COUNT + 1))
  else
    SKIPPED_LIST+=("${suffix}")
  fi
done < <(echo "$SSM_OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('Parameters', []):
    sys.stdout.write(p['Name'])
    sys.stdout.write('\\0')
    sys.stdout.write(p['Value'])
    sys.stdout.write('\\0')
")

chmod 0600 "$TMPFILE"
chown fjcloud:fjcloud "$TMPFILE" 2>/dev/null || true
mv "$TMPFILE" "$ENV_FILE"

echo "==> Wrote ${ENV_FILE} (${MAPPED_COUNT} SSM params mapped, static vars: ${STATIC_VAR_COUNT})"
if [[ ${#SKIPPED_LIST[@]} -gt 0 ]]; then
  echo "    Skipped SSM params (no mapping):"
  printf '  %s\n' "${SKIPPED_LIST[@]}"
fi

if [[ "${FJCLOUD_SKIP_METERING_ENV_GENERATION:-}" == "1" ]]; then
  echo "==> Skipping metering-env generation (FJCLOUD_SKIP_METERING_ENV_GENERATION=1)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Write /etc/fjcloud/metering-env from the same owner chain + node metadata
# ---------------------------------------------------------------------------

fetch_imds_token() {
  curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

imds_get() {
  local path="$1"
  local url="http://169.254.169.254/latest/${path}"
  if [[ -n "${IMDS_TOKEN:-}" ]]; then
    curl -fsS -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" "$url"
  else
    curl -fsS "$url"
  fi
}

IMDS_TOKEN="$(fetch_imds_token 2>/dev/null || true)"
INSTANCE_REGION="$(imds_get meta-data/placement/region 2>/dev/null || true)"
if [[ -n "$INSTANCE_REGION" ]]; then
  REGION="$INSTANCE_REGION"
fi

CUSTOMER_ID="$(imds_get meta-data/tags/instance/customer_id 2>/dev/null || true)"
NODE_ID="$(imds_get meta-data/tags/instance/node_id 2>/dev/null || true)"

# IMDS-tag detection. customer_id/node_id are set on customer flapjack VMs by
# bootstrap.sh / terraform. The control-plane API server (deploy.sh's only
# target) does NOT have these tags — the metering-agent there has nothing
# meaningful to scrape (no localhost flapjack on the API server). When the
# tags are absent we skip metering-env generation entirely; the systemd unit's
# ConditionPathExists=/etc/fjcloud/metering-env then keeps fj-metering-agent
# stopped on those instances, which is the designed-in behavior. Customer-VM
# bootstrap is unaffected.
HAS_CUSTOMER_TAG=true
if [[ -z "$CUSTOMER_ID" || "$CUSTOMER_ID" == "None" || "$CUSTOMER_ID" == "404 - Not Found" ]]; then
  HAS_CUSTOMER_TAG=false
fi
if [[ -z "$NODE_ID" || "$NODE_ID" == "None" || "$NODE_ID" == "404 - Not Found" ]]; then
  HAS_CUSTOMER_TAG=false
fi

if [[ "$HAS_CUSTOMER_TAG" != "true" ]]; then
  echo "==> No customer_id/node_id IMDS tags — skipping metering-env generation (control-plane instance)"
  # Remove any stale metering-env so fj-metering-agent's ConditionPathExists
  # honors the actual configuration rather than a previous hand-fabricated file.
  rm -f "$METERING_ENV_FILE"
  exit 0
fi

FLAPJACK_API_KEY=$(aws ssm get-parameter \
  --name "/fjcloud/${NODE_ID}/api-key" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "$REGION")

DATABASE_URL="$(get_resolved_value "DATABASE_URL")"
DNS_DOMAIN="$(get_resolved_value "DNS_DOMAIN")"
INTERNAL_AUTH_TOKEN_VALUE="$(get_resolved_value "INTERNAL_AUTH_TOKEN")"
ENVIRONMENT_VALUE="$(get_resolved_value "ENVIRONMENT")"
SLACK_WEBHOOK_URL="$(get_resolved_value "SLACK_WEBHOOK_URL")"
DISCORD_WEBHOOK_URL="$(get_resolved_value "DISCORD_WEBHOOK_URL")"
if [[ -n "$INTERNAL_AUTH_TOKEN_VALUE" ]]; then
  INTERNAL_KEY="$INTERNAL_AUTH_TOKEN_VALUE"
else
  INTERNAL_KEY="$FLAPJACK_API_KEY"
fi
if [[ -z "$ENVIRONMENT_VALUE" ]]; then
  ENVIRONMENT_VALUE="$ENV"
fi

if [[ -z "$DATABASE_URL" ]]; then
  echo "ERROR: DATABASE_URL missing from ${ENV_FILE} mapping"
  exit 1
fi
if [[ -z "$DNS_DOMAIN" ]]; then
  echo "ERROR: DNS_DOMAIN missing from ${ENV_FILE} mapping"
  exit 1
fi

METERING_TMPFILE=$(mktemp "${METERING_ENV_FILE}.XXXXXX")

{
  printf '%s\n' "# Generated by generate_ssm_env.sh — do not edit manually"
  printf '%s\n' "# Environment: ${ENVIRONMENT_VALUE}"
  printf '%s\n' "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  append_envfile_line "$METERING_TMPFILE" "DATABASE_URL" "$DATABASE_URL"
  append_envfile_line "$METERING_TMPFILE" "FLAPJACK_URL" "http://${NODE_ID}:7700"
  append_envfile_line "$METERING_TMPFILE" "FLAPJACK_API_KEY" "$FLAPJACK_API_KEY"
  append_envfile_line "$METERING_TMPFILE" "INTERNAL_KEY" "$INTERNAL_KEY"
  append_envfile_line "$METERING_TMPFILE" "CUSTOMER_ID" "$CUSTOMER_ID"
  append_envfile_line "$METERING_TMPFILE" "NODE_ID" "$NODE_ID"
  append_envfile_line "$METERING_TMPFILE" "REGION" "$REGION"
  append_envfile_line "$METERING_TMPFILE" "ENVIRONMENT" "$ENVIRONMENT_VALUE"
  append_envfile_line "$METERING_TMPFILE" "TENANT_MAP_URL" "https://api.${DNS_DOMAIN}/internal/tenant-map"
  append_envfile_line "$METERING_TMPFILE" "COLD_STORAGE_USAGE_URL" "https://api.${DNS_DOMAIN}/internal/cold-storage-usage"
  append_envfile_line "$METERING_TMPFILE" "SLACK_WEBHOOK_URL" "$SLACK_WEBHOOK_URL"
  append_envfile_line "$METERING_TMPFILE" "DISCORD_WEBHOOK_URL" "$DISCORD_WEBHOOK_URL"
} > "$METERING_TMPFILE"

chmod 0600 "$METERING_TMPFILE"
chown fjcloud:fjcloud "$METERING_TMPFILE" 2>/dev/null || true
mv "$METERING_TMPFILE" "$METERING_ENV_FILE"

echo "==> Wrote ${METERING_ENV_FILE} (metering runtime contract)"
