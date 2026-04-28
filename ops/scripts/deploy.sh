#!/usr/bin/env bash
# deploy.sh — Zero-downtime deploy via SSM (no SSH keys)
# Called from CI after binaries are uploaded to S3.
#
# Usage: deploy.sh <env> <git-sha>
#
# Flow:
#   1. Discover EC2 instance by Name tag
#   2. Save previous SHA to SSM for rollback
#   3. Send SSM command to instance:
#      a. Download binaries + migrations from S3
#      b. Run migrations (fail fast before binary swap)
#      c. Atomic binary swap (mv)
#      d. Restart services
#      e. Health check — rollback on failure
#   4. Poll SSM command status until completion

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/scripts/lib/deploy_validation.sh
source "$SCRIPT_DIR/lib/deploy_validation.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

if [[ $# -ne 2 ]]; then
  echo "Usage: deploy.sh <env> <git-sha>"
  echo "  env:     staging | prod"
  echo "  git-sha: full 40-char SHA of the release commit"
  exit 1
fi

ENV="$1"
SHA="$2"
REGION="us-east-1"
S3_BUCKET="fjcloud-releases-${ENV}"
S3_PREFIX="${ENV}/${SHA}"
SSM_LAST_SHA="/fjcloud/${ENV}/last_deploy_sha"
SSM_CANARY_QUIET_UNTIL="/fjcloud/${ENV}/canary_quiet_until"
CANARY_QUIET_WINDOW_SECONDS=1800

if [[ "$ENV" != "staging" && "$ENV" != "prod" ]]; then
  echo "ERROR: env must be 'staging' or 'prod' (got: ${ENV})"
  exit 1
fi

if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: git-sha must be a 40-character lowercase hexadecimal commit SHA"
  exit 1
fi

echo "==> Deploying ${SHA} to ${ENV}"

# ---------------------------------------------------------------------------
# Pre-deployment validation gate
# ---------------------------------------------------------------------------

predeploy_validate_release "$ENV" "$SHA" "$REGION"

# ---------------------------------------------------------------------------
# Discover instance by tag
# ---------------------------------------------------------------------------

echo "==> Looking up instance fjcloud-api-${ENV}"

INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Name,Values=fjcloud-api-${ENV}" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "ERROR: No running instance found with tag Name=fjcloud-api-${ENV}"
  exit 1
fi

echo "    Instance: ${INSTANCE_ID}"

# ---------------------------------------------------------------------------
# Save previous SHA for rollback
# ---------------------------------------------------------------------------

PREV_SHA=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "$SSM_LAST_SHA" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "")

if [[ -n "$PREV_SHA" && "$PREV_SHA" != "None" ]]; then
  echo "==> Previous deploy SHA: ${PREV_SHA}"
else
  echo "==> No previous deploy SHA found (first deploy)"
  PREV_SHA=""
fi

aws ssm put-parameter \
  --region "$REGION" \
  --name "$SSM_LAST_SHA" \
  --value "$SHA" \
  --type String \
  --overwrite

echo "==> Saved current SHA to ${SSM_LAST_SHA}"

# ---------------------------------------------------------------------------
# Build on-instance script
# ---------------------------------------------------------------------------

# The on-instance script runs as root via SSM RunShellScript.
# It downloads, migrates, swaps, restarts, and health-checks.

read -r -d '' INSTANCE_SCRIPT << 'EOFSCRIPT' || true
#!/usr/bin/env bash
set -euo pipefail

ENV="__ENV__"
SHA="__SHA__"
PREV_SHA="__PREV_SHA__"
S3_BUCKET="__S3_BUCKET__"
S3_PREFIX="__S3_PREFIX__"
REGION="__REGION__"

BINARIES=(fjcloud-api fjcloud-aggregation-job fj-metering-agent)
BIN_DIR="/usr/local/bin"
MIGRATIONS_DIR="/opt/fjcloud/migrations"
SCRIPTS_DIR="/opt/fjcloud/scripts"

echo "==> [instance] Starting deploy of ${SHA}"

# --- Download binaries as *.new ---
for bin in "${BINARIES[@]}"; do
  echo "    Downloading ${bin}"
  aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${bin}" "${BIN_DIR}/${bin}.new" --region "$REGION"
  chmod +x "${BIN_DIR}/${bin}.new"
done

# --- Download migrations ---
mkdir -p "$MIGRATIONS_DIR"
aws s3 sync "s3://${S3_BUCKET}/${S3_PREFIX}/migrations/" "$MIGRATIONS_DIR/" --region "$REGION" --delete

# --- Download migrate.sh ---
mkdir -p "$SCRIPTS_DIR"
aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/scripts/migrate.sh" "${SCRIPTS_DIR}/migrate.sh" --region "$REGION"
aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/scripts/generate_ssm_env.sh" "${SCRIPTS_DIR}/generate_ssm_env.sh" --region "$REGION"
chmod +x "${SCRIPTS_DIR}/migrate.sh" "${SCRIPTS_DIR}/generate_ssm_env.sh"

# --- Generate runtime env files from SSM parameters ---
echo "==> [instance] Generating runtime env files from SSM"
"${SCRIPTS_DIR}/generate_ssm_env.sh" "$ENV"
METERING_ENV_FILE="/etc/fjcloud/metering-env"
if [[ ! -s "$METERING_ENV_FILE" ]]; then
  echo "ERROR: missing metering runtime env contract at $METERING_ENV_FILE"
  exit 1
fi
for var_name in DATABASE_URL FLAPJACK_URL FLAPJACK_API_KEY INTERNAL_KEY CUSTOMER_ID NODE_ID REGION ENVIRONMENT TENANT_MAP_URL COLD_STORAGE_USAGE_URL SLACK_WEBHOOK_URL DISCORD_WEBHOOK_URL; do
  if ! grep -q "^${var_name}=" "$METERING_ENV_FILE"; then
    echo "ERROR: $METERING_ENV_FILE missing ${var_name}"
    exit 1
  fi
done

# --- Run migrations (fail fast before binary swap) ---
echo "==> [instance] Running migrations"
"${SCRIPTS_DIR}/migrate.sh" "$ENV"

# --- Back up current binaries ---
for bin in "${BINARIES[@]}"; do
  if [[ -f "${BIN_DIR}/${bin}" ]]; then
    cp "${BIN_DIR}/${bin}" "${BIN_DIR}/${bin}.old"
  fi
done

# --- Atomic binary swap ---
echo "==> [instance] Swapping binaries"
for bin in "${BINARIES[@]}"; do
  mv "${BIN_DIR}/${bin}.new" "${BIN_DIR}/${bin}"
done

# --- Restart services ---
echo "==> [instance] Restarting fjcloud-api and fj-metering-agent"
systemctl restart fjcloud-api
systemctl restart fj-metering-agent

# --- Health check loop (max 30s, 1s interval) ---
echo "==> [instance] Health check"
HEALTHY=false
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:3001/health > /dev/null 2>&1; then
    echo "    Healthy after ${i}s"
    HEALTHY=true
    break
  fi
  sleep 1
done

if [[ "$HEALTHY" == "true" ]]; then
  echo "==> [instance] Deploy successful"
  # Clean up .old backups
  for bin in "${BINARIES[@]}"; do
    rm -f "${BIN_DIR}/${bin}.old"
  done
  exit 0
fi

# --- Rollback on health check failure ---
echo "==> [instance] Health check FAILED — rolling back"
for bin in "${BINARIES[@]}"; do
  if [[ -f "${BIN_DIR}/${bin}.old" ]]; then
    mv "${BIN_DIR}/${bin}.old" "${BIN_DIR}/${bin}"
  fi
done
systemctl restart fjcloud-api
systemctl restart fj-metering-agent

echo "==> [instance] Rolled back to previous binaries"
exit 1
EOFSCRIPT

# Substitute placeholders with actual values
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__ENV__/$ENV}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__SHA__/$SHA}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__PREV_SHA__/${PREV_SHA:-none}}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__S3_BUCKET__/$S3_BUCKET}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__S3_PREFIX__/$S3_PREFIX}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__REGION__/$REGION}"

# ---------------------------------------------------------------------------
# Send SSM command
# ---------------------------------------------------------------------------

CANARY_QUIET_UNTIL="$(
  python3 - "$CANARY_QUIET_WINDOW_SECONDS" <<'PY'
from datetime import datetime, timedelta, timezone
import sys

quiet_window_seconds = int(sys.argv[1])
quiet_until = datetime.now(timezone.utc) + timedelta(seconds=quiet_window_seconds)
print(quiet_until.replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

aws ssm put-parameter \
  --region "$REGION" \
  --name "$SSM_CANARY_QUIET_UNTIL" \
  --value "$CANARY_QUIET_UNTIL" \
  --type String \
  --overwrite

echo "==> Set canary quiet window until ${CANARY_QUIET_UNTIL}"

echo "==> Sending SSM command to ${INSTANCE_ID}"

COMMAND_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "$(echo "$INSTANCE_SCRIPT" | jq -R -s 'split("\n") | {"commands": .}')" \
  --timeout-seconds 300 \
  --comment "fjcloud deploy ${SHA}" \
  --query 'Command.CommandId' \
  --output text)

echo "    Command ID: ${COMMAND_ID}"

# ---------------------------------------------------------------------------
# Poll SSM command status
# ---------------------------------------------------------------------------

echo "==> Polling command status"

MAX_POLL_ITERATIONS=120  # 10 minutes at 5s intervals
POLL_ITERATION=0

while [[ $POLL_ITERATION -lt $MAX_POLL_ITERATIONS ]]; do
  STATUS=$(aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'Status' \
    --output text 2>/dev/null || echo "Pending")

  case "$STATUS" in
    Success)
      echo "==> Deploy complete: ${SHA} → ${ENV}"
      exit 0
      ;;
    Failed|TimedOut|Cancelled)
      echo "ERROR: SSM command ${STATUS}"
      # Print command output for debugging
      aws ssm get-command-invocation \
        --region "$REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query '[StandardOutputContent, StandardErrorContent]' \
        --output text 2>/dev/null || true
      # Restore previous SHA on failure
      if [[ -n "$PREV_SHA" && "$PREV_SHA" != "None" ]]; then
        aws ssm put-parameter \
          --region "$REGION" \
          --name "$SSM_LAST_SHA" \
          --value "$PREV_SHA" \
          --type String \
          --overwrite
      else
        aws ssm delete-parameter \
          --region "$REGION" \
          --name "$SSM_LAST_SHA"
      fi
      exit 1
      ;;
    *)
      # InProgress, Pending, Delayed
      sleep 5
      ;;
  esac
  POLL_ITERATION=$((POLL_ITERATION + 1))
done

echo "ERROR: SSM command polling timed out after $((MAX_POLL_ITERATIONS * 5)) seconds"
exit 1
