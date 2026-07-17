#!/usr/bin/env bash
# rollback.sh — Roll back to a previous release via SSM
# Does NOT run migrations (never roll back migrations).
#
# Usage: rollback.sh <env> <previous-sha>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--contract-probe" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/rollback_compatibility.sh"
  shift
  rollback_contract_probe "$@"
  exit $?
fi

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
SSM_LEGACY_SAFE_SHA="/fjcloud/${ENV}/algolia_import_legacy_safe_mirror_sha"

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

LEGACY_SAFE_MIRROR_SHA=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "$SSM_LEGACY_SAFE_SHA" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || true)
if [[ ! "$LEGACY_SAFE_MIRROR_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  LEGACY_SAFE_MIRROR_SHA=""
fi

# ---------------------------------------------------------------------------
# Build on-instance script (NO migrations)
# ---------------------------------------------------------------------------

if command -v sha256sum >/dev/null 2>&1; then
  ROLLBACK_LIBRARY_SHA256=$(sha256sum "${SCRIPT_DIR}/lib/rollback_compatibility.sh" | awk '{print $1}')
else
  ROLLBACK_LIBRARY_SHA256=$(shasum -a 256 "${SCRIPT_DIR}/lib/rollback_compatibility.sh" | awk '{print $1}')
fi

read -r -d '' INSTANCE_SCRIPT << 'EOFSCRIPT' || true
#!/usr/bin/env bash
set -euo pipefail

ENV="__ENV__"
SHA="__SHA__"
S3_BUCKET="__S3_BUCKET__"
S3_PREFIX="__S3_PREFIX__"
REGION="__REGION__"
LEGACY_SAFE_MIRROR_SHA="__LEGACY_SAFE_MIRROR_SHA__"
ROLLBACK_LIBRARY_SHA256="__ROLLBACK_LIBRARY_SHA256__"

# fj-metering-agent intentionally excluded here: customer flapjack VMs own
# that lifecycle via ops/user-data/bootstrap.sh, while this script targets the
# control-plane API host only.
BINARIES=(fjcloud-api fjcloud-aggregation-job fjcloud-retention-job)
BIN_DIR="/usr/local/bin"
CANDIDATE_DIR="$(mktemp -d /var/tmp/fjcloud-rollback-candidate.XXXXXX)"
SOURCE_MANIFEST="${CANDIDATE_DIR}/rollback_contract.release.json"
PROBE_MANIFEST="${CANDIDATE_DIR}/rollback_contract.json"
DATABASE_COPY="${CANDIDATE_DIR}/database.snapshot"
PROBE_LIBRARY="/usr/local/lib/fjcloud/rollback_compatibility.sh"

cleanup_rollback_candidate() {
  rm -rf "$CANDIDATE_DIR"
}
trap cleanup_rollback_candidate EXIT

echo "==> [instance] Rolling back to ${SHA}"

[[ -r "$PROBE_LIBRARY" ]] || {
  echo "ERROR: installed rollback compatibility gate is missing" >&2
  exit 1
}
if command -v sha256sum >/dev/null 2>&1; then
  INSTALLED_LIBRARY_SHA256=$(sha256sum "$PROBE_LIBRARY" | awk '{print $1}')
else
  INSTALLED_LIBRARY_SHA256=$(shasum -a 256 "$PROBE_LIBRARY" | awk '{print $1}')
fi
[[ "$INSTALLED_LIBRARY_SHA256" == "$ROLLBACK_LIBRARY_SHA256" ]] || {
  echo "ERROR: installed rollback compatibility gate differs from the invoking checkout" >&2
  exit 1
}

# shellcheck disable=SC1090
source "$PROBE_LIBRARY"
export ROLLBACK_CANDIDATE_ENV_FILE="/etc/fjcloud/env"
rollback_load_candidate_environment >/dev/null

[[ -n "${DATABASE_URL:-}" ]] || {
  echo "ERROR: /etc/fjcloud/env does not define DATABASE_URL" >&2
  exit 1
}

IFS=$'\t' read -r ROLLBACK_EPOCH REQUIRED_SCHEMA_FLOOR REQUIRED_PROTOCOL_FLOOR < <(
  PGDATABASE="$DATABASE_URL" psql -X -A -t -F $'\t' -v ON_ERROR_STOP=1 -c \
    "SELECT rollback_epoch, min_migration_schema_floor, min_protocol_floor FROM algolia_import_environment_contract WHERE singleton = TRUE"
)
case "$ROLLBACK_EPOCH" in
  pre_admission|migration_aware_required) ;;
  *) echo "ERROR: database returned an invalid Algolia import rollback epoch" >&2; exit 1 ;;
esac

# --- Materialize the exact unswapped release bundle ---
for bin in "${BINARIES[@]}"; do
  echo "    Downloading ${bin}"
  aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${bin}" "${CANDIDATE_DIR}/${bin}" --region "$REGION"
  chmod +x "${CANDIDATE_DIR}/${bin}"
done

if [[ "$ROLLBACK_EPOCH" == "pre_admission" ]]; then
  [[ "$SHA" == "$LEGACY_SAFE_MIRROR_SHA" ]] || {
    echo "ERROR: pre-admission rollback is restricted to the frozen legacy safe mirror" >&2
    exit 1
  }
  echo "==> [instance] Frozen legacy rollback mirror accepted before first dispatch intent"
else
  if ! command -v initdb >/dev/null 2>&1 \
    || ! command -v pg_ctl >/dev/null 2>&1 \
    || ! command -v createdb >/dev/null 2>&1 \
    || ! command -v pg_restore >/dev/null 2>&1 \
    || ! command -v pg_dump >/dev/null 2>&1; then
    echo "==> [instance] Installing isolated rollback-proof PostgreSQL tooling"
    dnf install -y postgresql16-server
    hash -r
  fi

  aws s3 cp \
    "s3://${S3_BUCKET}/${S3_PREFIX}/rollback_contract.json" \
    "$SOURCE_MANIFEST" \
    --region "$REGION"
  SOURCE_MIRROR_SHA=$(jq -r '.mirror_sha // empty' "$SOURCE_MANIFEST")
  EXPECTED_DEV_SHA=$(jq -r '.dev_sha // empty' "$SOURCE_MANIFEST")
  [[ "$SOURCE_MIRROR_SHA" == "$SHA" ]] || {
    echo "ERROR: release contract mirror SHA does not match requested rollback SHA" >&2
    exit 1
  }
  [[ "$EXPECTED_DEV_SHA" =~ ^[0-9a-f]{40}$ ]] || {
    echo "ERROR: release contract dev SHA is invalid" >&2
    exit 1
  }

  CANDIDATE_PORT=$(rollback_free_loopback_port)
  CANDIDATE_ORIGIN="http://127.0.0.1:${CANDIDATE_PORT}"
  jq \
    --arg epoch "$ROLLBACK_EPOCH" \
    --arg origin "$CANDIDATE_ORIGIN" \
    --argjson now "$(date +%s)" \
    --argjson schema_floor "$REQUIRED_SCHEMA_FLOOR" \
    --argjson protocol_floor "$REQUIRED_PROTOCOL_FLOOR" \
    '
      .rollback_epoch = $epoch
      | .generated_at_epoch = $now
      | .max_manifest_age_seconds = 300
      | .required_schema_floor = $schema_floor
      | .required_protocol_floor = $protocol_floor
      | .served_version_url = ($origin + "/version")
      | .served_state_url = ($origin + (.served_state_path // "/state"))
      | .protocol_fixtures = [(.protocol_fixtures // [])[] | .url = ($origin + .path)]
    ' "$SOURCE_MANIFEST" > "$PROBE_MANIFEST"

  # The shared proof restores this consistent archive into isolated PostgreSQL
  # and never points the candidate at the live database.
  PGDATABASE="$DATABASE_URL" pg_dump --format=custom \
    --no-owner \
    --no-privileges \
    --file="$DATABASE_COPY"

  echo "==> [instance] Proving rollback candidate compatibility"
  if ! PROOF_RESULT="$(rollback_contract_probe \
    --candidate-artifact "$CANDIDATE_DIR" \
    --database-copy "$DATABASE_COPY" \
    --candidate-manifest "$PROBE_MANIFEST" \
    --expected-served-sha "$EXPECTED_DEV_SHA")"; then
    echo "$PROOF_RESULT" >&2
    echo "ERROR: rollback candidate compatibility proof failed; binaries remain unswapped" >&2
    exit 1
  fi
  jq -e '.status == "ok"' <<<"$PROOF_RESULT" >/dev/null || {
    echo "ERROR: rollback candidate compatibility proof returned a non-green result" >&2
    exit 1
  }
  echo "$PROOF_RESULT"
fi

# Metering-agent unit convergence is intentionally not part of the API-server
# rollback path. Customer flapjack VMs fetch and manage that unit through
# ops/user-data/bootstrap.sh, which is the canonical owner of its lifecycle.

# --- Back up current binaries ---
for bin in "${BINARIES[@]}"; do
  if [[ -f "${BIN_DIR}/${bin}" ]]; then
    cp "${BIN_DIR}/${bin}" "${BIN_DIR}/${bin}.old"
  fi
done

# --- Swap binaries ---
echo "==> [instance] Swapping binaries"
for bin in "${BINARIES[@]}"; do
  mv "${CANDIDATE_DIR}/${bin}" "${BIN_DIR}/${bin}"
done

# --- Restart services ---
echo "==> [instance] Restarting fjcloud-api"
systemctl restart fjcloud-api

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
echo "==> [instance] Restored previous binaries"
exit 1
EOFSCRIPT

# Substitute placeholders
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__ENV__/$ENV}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__SHA__/$SHA}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__S3_BUCKET__/$S3_BUCKET}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__S3_PREFIX__/$S3_PREFIX}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__REGION__/$REGION}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__LEGACY_SAFE_MIRROR_SHA__/$LEGACY_SAFE_MIRROR_SHA}"
INSTANCE_SCRIPT="${INSTANCE_SCRIPT//__ROLLBACK_LIBRARY_SHA256__/$ROLLBACK_LIBRARY_SHA256}"

# ---------------------------------------------------------------------------
# Send SSM command
# ---------------------------------------------------------------------------

echo "==> Sending SSM command to ${INSTANCE_ID}"

COMMAND_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "$(echo "$INSTANCE_SCRIPT" | jq -R -s 'split("\n") | {"commands": .}')" \
  --timeout-seconds 900 \
  --comment "fjcloud rollback to ${SHA}" \
  --query 'Command.CommandId' \
  --output text)

echo "    Command ID: ${COMMAND_ID}"

# ---------------------------------------------------------------------------
# Poll SSM command status
# ---------------------------------------------------------------------------

echo "==> Polling command status"

MAX_POLL_ITERATIONS=240  # 20 minutes at 5s intervals
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
