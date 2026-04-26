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
#   eval "$(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)"
#   bash scripts/launch/capture_stage_d_evidence.sh

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
  echo "ERROR: API_URL or ADMIN_KEY not set. Source .secret/.env.secret and eval scripts/launch/hydrate_seeder_env_from_ssm.sh staging first." >&2
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
# Step 5a: refresh /opt/fjcloud-runtime-fix on staging so the rehearsal
# runs against current main, not whatever stale checkout was left there
# -----------------------------------------------------------------------------
echo "==> [5a/5] refresh /opt/fjcloud-runtime-fix from staging mirror HEAD"
if ! bash "$SCRIPT_DIR/refresh_staging_runtime_checkout.sh" \
    > "${ARTIFACT_DIR}/05a_runtime_checkout_refresh.log" 2>&1; then
  echo "FAIL: refresh_staging_runtime_checkout.sh exited non-zero. See ${ARTIFACT_DIR}/05a_runtime_checkout_refresh.log" >&2
  tail -40 "${ARTIFACT_DIR}/05a_runtime_checkout_refresh.log" >&2
  exit 1
fi
refreshed_path="$(grep -E "^REFRESHED_RUNTIME_PATH=" "${ARTIFACT_DIR}/05a_runtime_checkout_refresh.log" | tail -1 | sed 's/^REFRESHED_RUNTIME_PATH=//')"
if [ -z "$refreshed_path" ]; then
  echo "FAIL: refresh wrapper did not emit REFRESHED_RUNTIME_PATH" >&2
  exit 1
fi
echo "OK: staging runtime checkout refreshed at ${refreshed_path}"

# -----------------------------------------------------------------------------
# Step 5b: drive the rehearsal via SSM against the freshly-refreshed
# checkout (DATABASE_URL is RDS-internal, so the rehearsal can only run
# from the staging EC2 host)
# -----------------------------------------------------------------------------
echo "==> [5b/5] drive staging billing rehearsal via SSM"
month="$(date -u +%Y-%m)"
echo "    month: ${month}"
echo "    runtime: ${refreshed_path}"

REHEARSAL_CMD="cd ${refreshed_path} && bash scripts/staging_billing_rehearsal.sh \
  --month ${month} --confirm-live-mutation"

# The rehearsal sequences many DB+Stripe steps; the default 300s SSM
# wrapper timeout is tight. Give it 15 min before declaring TimedOut.
if ! SSM_EXEC_TIMEOUT_SECONDS="${STAGE_D_REHEARSAL_TIMEOUT_SECONDS:-900}" \
    bash "$SCRIPT_DIR/ssm_exec_staging.sh" "$REHEARSAL_CMD" \
    > "${ARTIFACT_DIR}/05b_rehearsal_via_ssm.log" 2>&1; then
  echo "WARN: rehearsal via SSM exited non-zero. Inspect ${ARTIFACT_DIR}/05b_rehearsal_via_ssm.log" >&2
  tail -40 "${ARTIFACT_DIR}/05b_rehearsal_via_ssm.log" >&2
  exit 1
fi
tail -20 "${ARTIFACT_DIR}/05b_rehearsal_via_ssm.log"

echo
echo "==> DONE. Stage D evidence captured under:"
echo "    ${ARTIFACT_DIR}"
