#!/usr/bin/env bash
# rollback.sh — Roll back to a previous release via SSM
# Does NOT run migrations (never roll back migrations).
#
# Usage: rollback.sh <env> <previous-sha>

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

if [[ $# -ne 2 ]]; then
  echo "Usage: rollback.sh <env> <previous-sha>"
  echo "  env:          staging | prod"
  echo "  previous-sha: full 40-char SHA to roll back to"
  exit 1
fi

ENV="$1"
SHA="$2"
REGION="us-east-1"
S3_BUCKET="fjcloud-releases-${ENV}"
S3_PREFIX="${ENV}/${SHA}"
SSM_LAST_SHA="/fjcloud/${ENV}/last_deploy_sha"

if [[ "$ENV" != "staging" && "$ENV" != "prod" ]]; then
  echo "ERROR: env must be 'staging' or 'prod' (got: ${ENV})"
  exit 1
fi

if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: previous-sha must be a 40-character lowercase hexadecimal commit SHA"
  exit 1
fi

echo "==> Rolling back ${ENV} to ${SHA}"

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
# Build on-instance script (NO migrations)
# ---------------------------------------------------------------------------

read -r -d '' INSTANCE_SCRIPT << 'EOFSCRIPT' || true
#!/usr/bin/env bash
set -euo pipefail

SHA="__SHA__"
S3_BUCKET="__S3_BUCKET__"
S3_PREFIX="__S3_PREFIX__"
REGION="__REGION__"

BINARIES=(fjcloud-api fjcloud-aggregation-job fj-metering-agent)
BIN_DIR="/usr/local/bin"
SYSTEMD_ARTIFACT_DIR="/opt/fjcloud/systemd"

echo "==> [instance] Rolling back to ${SHA}"

# --- Download previous binaries ---
for bin in "${BINARIES[@]}"; do
  echo "    Downloading ${bin}"
  aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${bin}" "${BIN_DIR}/${bin}.new" --region "$REGION"
  chmod +x "${BIN_DIR}/${bin}.new"
done

# --- Download and install systemd units that must converge with the repo ---
mkdir -p "$SYSTEMD_ARTIFACT_DIR"
aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/systemd/fj-metering-agent.service" "${SYSTEMD_ARTIFACT_DIR}/fj-metering-agent.service" --region "$REGION"
install -m 0644 "${SYSTEMD_ARTIFACT_DIR}/fj-metering-agent.service" /etc/systemd/system/fj-metering-agent.service
systemctl daemon-reload
systemctl enable fj-metering-agent

# --- Back up current binaries ---
for bin in "${BINARIES[@]}"; do
  if [[ -f "${BIN_DIR}/${bin}" ]]; then
    cp "${BIN_DIR}/${bin}" "${BIN_DIR}/${bin}.old"
  fi
done

# --- Swap binaries ---
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
  echo "==> [instance] Rollback successful"
  for bin in "${BINARIES[@]}"; do
    rm -f "${BIN_DIR}/${bin}.old"
  done
  exit 0
fi

# --- Restore on health check failure ---
echo "==> [instance] Health check FAILED — restoring previous binaries"
for bin in "${BINARIES[@]}"; do
  if [[ -f "${BIN_DIR}/${bin}.old" ]]; then
    mv "${BIN_DIR}/${bin}.old" "${BIN_DIR}/${bin}"
  fi
done
systemctl restart fjcloud-api
systemctl restart fj-metering-agent
echo "==> [instance] Restored previous binaries"
exit 1
EOFSCRIPT

# Substitute placeholders
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__SHA__/$SHA}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__S3_BUCKET__/$S3_BUCKET}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__S3_PREFIX__/$S3_PREFIX}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__REGION__/$REGION}"

# ---------------------------------------------------------------------------
# Send SSM command
# ---------------------------------------------------------------------------

echo "==> Sending SSM command to ${INSTANCE_ID}"

COMMAND_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "$(echo "$INSTANCE_SCRIPT" | jq -R -s 'split("\n") | {"commands": .}')" \
  --timeout-seconds 300 \
  --comment "fjcloud rollback to ${SHA}" \
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
      echo "==> Rollback complete: ${ENV} → ${SHA}"
      # Update last_deploy_sha to the rolled-back version
      aws ssm put-parameter \
        --region "$REGION" \
        --name "$SSM_LAST_SHA" \
        --value "$SHA" \
        --type String \
        --overwrite
      exit 0
      ;;
    Failed|TimedOut|Cancelled)
      echo "ERROR: SSM command ${STATUS}"
      aws ssm get-command-invocation \
        --region "$REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query '[StandardOutputContent, StandardErrorContent]' \
        --output text 2>/dev/null || true
      exit 1
      ;;
    *)
      sleep 5
      ;;
  esac
  POLL_ITERATION=$((POLL_ITERATION + 1))
done

echo "ERROR: SSM command polling timed out after $((MAX_POLL_ITERATIONS * 5)) seconds"
exit 1
