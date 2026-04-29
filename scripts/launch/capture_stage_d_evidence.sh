#!/usr/bin/env bash
# capture_stage_d_evidence.sh — end-to-end Blocker-3 live evidence
# capture, owner-script style.
#
# Sequencing (each step gates the next):
#   1) Verify the deployed staging API picks up the tenant-map URL
#      fallback (i.e. infra/api/src/routes/internal.rs::tenant_map
#      from commit 019bc5b9 is live). If not, the rest of the script
#      cannot produce useful evidence.
#   2) Re-run the synthetic-traffic seeder for Tenant A so storage
#      stays converged AND a fresh window of writes overlaps the next
#      scheduler scrape cycle. Duration is tunable via
#      STAGE_D_SEEDER_DURATION_MINUTES (default 3).
#   3) Wait one scheduler cycle (default SCHEDULER_SCRAPE_INTERVAL_SECS=300,
#      so we sleep STAGE_D_SCHEDULER_WAIT_SECONDS=320 with 20s buffer).
#   4) Verify /admin/tenants/{id}/usage shows non-zero values for the
#      current month. If still zero, fail-closed with a diagnostic.
#   5) Drive the staging billing rehearsal via the SSM exec wrapper so
#      the rehearsal runs on the staging EC2 host (where DATABASE_URL
#      is reachable). Outputs go to docs/runbooks/evidence/staging-billing-rehearsal/
#      under a fresh timestamped subdir, plus a copy of the full SSM
#      stdout for debugging.
#
# Pre-conditions:
#   - .secret/.env.secret already sourced (AWS creds present)
#   - hydrate_seeder_env_from_ssm.sh has set ADMIN_KEY / API_URL etc.
#   - The new API binary (post-019bc5b9) is deployed on staging.
#   - /tmp/seed-synthetic-demo-shared-free.json exists with the live
#     mapping for Tenant A (the seeder writes/persists this).
#
# Usage:
#   set -a; source .secret/.env.secret; set +a
#   bash -lc 'source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging); bash scripts/launch/capture_stage_d_evidence.sh'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CUSTOMER_ID="${TENANT_A_CUSTOMER_ID:-0a65f0b7-14b3-4e08-acf6-2222a02c7858}"
SEEDER_DURATION_MINUTES="${STAGE_D_SEEDER_DURATION_MINUTES:-3}"
SCHEDULER_WAIT_SECONDS="${STAGE_D_SCHEDULER_WAIT_SECONDS:-320}"
EVIDENCE_DIR="${STAGE_D_EVIDENCE_DIR:-${REPO_ROOT}/docs/runbooks/evidence/staging-billing-rehearsal}"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR="${EVIDENCE_DIR}/${RUN_TS}_stage_d_capture"

if [ -z "${API_URL:-}" ] || [ -z "${ADMIN_KEY:-}" ]; then
  echo "ERROR: API_URL or ADMIN_KEY not set. Source .secret/.env.secret, then run this wrapper from a shell that sources scripts/launch/hydrate_seeder_env_from_ssm.sh staging without eval." >&2
  exit 64
fi

mkdir -p "$ARTIFACT_DIR"
echo "==> Stage D evidence capture, run=${RUN_TS}"
echo "    artifacts -> ${ARTIFACT_DIR}"

# -----------------------------------------------------------------------------
# Step 1: tenant-map URL fallback live?
# -----------------------------------------------------------------------------
echo "==> [1/5] verify tenant-map URL fallback live on staging"
if ! bash "$SCRIPT_DIR/post_deploy_verify_tenant_map.sh" \
  > "${ARTIFACT_DIR}/01_tenant_map_verify.txt" 2>&1; then
  echo "FAIL: tenant-map verifier rejected. See ${ARTIFACT_DIR}/01_tenant_map_verify.txt" >&2
  cat "${ARTIFACT_DIR}/01_tenant_map_verify.txt" >&2
  exit 1
fi
cat "${ARTIFACT_DIR}/01_tenant_map_verify.txt"

# -----------------------------------------------------------------------------
# Step 2: re-run seeder
# -----------------------------------------------------------------------------
echo "==> [2/5] re-run seeder for Tenant A (${SEEDER_DURATION_MINUTES} min)"
if ! bash "$SCRIPT_DIR/seed_synthetic_traffic.sh" \
    --tenant A --execute --i-know-this-hits-staging \
    --duration-minutes "$SEEDER_DURATION_MINUTES" \
    > "${ARTIFACT_DIR}/02_seeder_rerun.log" 2>&1; then
  echo "FAIL: seeder rerun failed. See ${ARTIFACT_DIR}/02_seeder_rerun.log" >&2
  tail -30 "${ARTIFACT_DIR}/02_seeder_rerun.log" >&2
  exit 1
fi
tail -10 "${ARTIFACT_DIR}/02_seeder_rerun.log"

# -----------------------------------------------------------------------------
# Step 3: wait one scheduler cycle
# -----------------------------------------------------------------------------
echo "==> [3/5] wait ${SCHEDULER_WAIT_SECONDS}s for scheduler scrape + aggregation"
sleep "$SCHEDULER_WAIT_SECONDS"

# -----------------------------------------------------------------------------
# Step 4: verify usage_records non-zero
# -----------------------------------------------------------------------------
echo "==> [4/5] verify /admin/tenants/${CUSTOMER_ID}/usage non-zero"
usage_response="$(curl -fsSL "${API_URL}/admin/tenants/${CUSTOMER_ID}/usage" \
  -H "x-admin-key: ${ADMIN_KEY}")"
echo "$usage_response" > "${ARTIFACT_DIR}/04_admin_usage.json"
echo "$usage_response"

zero_check="$(printf '%s' "$usage_response" | python3 -c '
import sys, json
payload = json.load(sys.stdin)
if (payload.get("total_search_requests", 0) > 0
    or payload.get("total_write_operations", 0) > 0
    or payload.get("avg_storage_gb", 0.0) > 0
    or payload.get("avg_document_count", 0) > 0):
    print("OK")
else:
    print("ZERO")
')"

if [ "$zero_check" != "OK" ]; then
  echo "FAIL: /admin/tenants/${CUSTOMER_ID}/usage is still all zero after ${SCHEDULER_WAIT_SECONDS}s." >&2
  echo "      The metering pipeline may need more than one scrape cycle, or" >&2
  echo "      the deploy may have not picked up the tenant-map fix yet." >&2
  echo "      Re-run after another scheduler cycle to retry." >&2
  exit 1
fi
echo "OK: usage_records have non-zero rows for tenant A"

# -----------------------------------------------------------------------------
# Step 5: drive the rehearsal via SSM. The rehearsal must run on the
# staging EC2 host (DATABASE_URL is RDS-internal). The deployed sha's
# source is already at /opt/fjcloud-runtime-fix/<sha>/src/ from the
# deploy step — no separate "refresh" hop needed (and the prior
# git-clone-based refresh broke the moment the staging mirror became
# private). The rehearsal env file is materialized on the EC2 host
# from SSM so credentials never traverse the operator side.
# -----------------------------------------------------------------------------
echo "==> [5/5] drive staging billing rehearsal via SSM"
month="$(date -u +%Y-%m)"
echo "    month: ${month}"

# Heredoc-as-script: read sha, verify the runtime checkout exists
# (deploy precondition), generate env from SSM, run rehearsal.
read -r -d '' REHEARSAL_REMOTE_SCRIPT <<'REMOTE_EOF' || true
set -euo pipefail
REGION="us-east-1"
ssm_get() {
  aws ssm get-parameter --name "$1" --with-decryption --region "$REGION" \
    --query Parameter.Value --output text
}
SHA="$(ssm_get /fjcloud/staging/last_deploy_sha)"
SRC_DIR="/opt/fjcloud-runtime-fix/${SHA}/src"
REHEARSAL_SH="${SRC_DIR}/scripts/staging_billing_rehearsal.sh"
if [[ ! -f "$REHEARSAL_SH" ]]; then
  echo "ERROR: ${REHEARSAL_SH} missing — deploy step must populate the source" >&2
  exit 1
fi
ENV_FILE="$(mktemp /tmp/fjcloud-rehearsal-env.XXXXXX)"
chmod 600 "$ENV_FILE"
trap 'rm -f "$ENV_FILE"' EXIT
DATABASE_URL=$(ssm_get /fjcloud/staging/database_url)
ADMIN_KEY=$(ssm_get /fjcloud/staging/admin_key)
STRIPE_SECRET_KEY=$(ssm_get /fjcloud/staging/stripe_secret_key)
STRIPE_WEBHOOK_SECRET=$(ssm_get /fjcloud/staging/stripe_webhook_secret)
cat > "$ENV_FILE" <<ENV_EOF
STAGING_API_URL=https://api.flapjack.foo
STAGING_STRIPE_WEBHOOK_URL=https://api.flapjack.foo/webhooks/stripe
STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY}
STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET}
ADMIN_KEY=${ADMIN_KEY}
DATABASE_URL=${DATABASE_URL}
ENV_EOF
cd "$SRC_DIR"
# __MONTH__ is a placeholder substituted operator-side after the outer
# heredoc is read (the outer heredoc is single-quoted to keep the inner
# `${STRIPE_SECRET_KEY}` etc. unexpanded until the script runs on EC2).
bash scripts/staging_billing_rehearsal.sh \
  --env-file "$ENV_FILE" \
  --month "__MONTH__" \
  --confirm-live-mutation
REMOTE_EOF
REHEARSAL_CMD="${REHEARSAL_REMOTE_SCRIPT//__MONTH__/${month}}"

# The rehearsal sequences many DB+Stripe steps; the default 300s SSM
# wrapper timeout is tight. Give it 15 min before declaring TimedOut.
if ! SSM_EXEC_TIMEOUT_SECONDS="${STAGE_D_REHEARSAL_TIMEOUT_SECONDS:-900}" \
    bash "$SCRIPT_DIR/ssm_exec_staging.sh" "$REHEARSAL_CMD" \
    > "${ARTIFACT_DIR}/05_rehearsal_via_ssm.log" 2>&1; then
  echo "WARN: rehearsal via SSM exited non-zero. Inspect ${ARTIFACT_DIR}/05_rehearsal_via_ssm.log" >&2
  tail -40 "${ARTIFACT_DIR}/05_rehearsal_via_ssm.log" >&2
  exit 1
fi
tail -20 "${ARTIFACT_DIR}/05_rehearsal_via_ssm.log"

echo
echo "==> DONE. Stage D evidence captured under:"
echo "    ${ARTIFACT_DIR}"
