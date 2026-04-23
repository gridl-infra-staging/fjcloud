#!/usr/bin/env bash
# ha-failover-proof.sh — run an end-to-end local HA failover proof.
#
# Workflow:
# 1) choose a cross-region active replica whose primary is in target region
# 2) kill the primary VM
# 3) wait for region-down + failover alerts
# 4) restart region processes
# 5) wait for recovery alert
# 6) verify tenant remains on promoted VM (no automatic switchback)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=../lib/health.sh
source "$REPO_ROOT/scripts/lib/health.sh"
# shellcheck source=../lib/flapjack_binary.sh
source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"

log() { echo "[ha-failover-proof] $*"; }
error() { echo "[ha-failover-proof] ERROR: $*" >&2; }

usage() {
    echo "Usage: ha-failover-proof.sh <region>" >&2
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || {
        error "Missing required dependency: $command_name"
        exit 1
    }
}

resolve_positive_int() {
    local raw_value="$1"
    local fallback="$2"

    if [[ "$raw_value" =~ ^[0-9]+$ ]] && [ "$raw_value" -gt 0 ]; then
        printf '%s\n' "$raw_value"
        return 0
    fi

    printf '%s\n' "$fallback"
}

at_least() {
    local raw_value="$1"
    local minimum="$2"

    if [ "$raw_value" -lt "$minimum" ]; then
        printf '%s\n' "$minimum"
        return 0
    fi

    printf '%s\n' "$raw_value"
}

is_loopback_api_base_url() {
    local url="$1"

    [[ "$url" =~ ^https?://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?/?$ ]]
}

iso_utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

api_request() {
    local method="$1"
    local path="$2"
    shift 2

    curl -sf -X "$method" "${API_URL}${path}" \
        -H "x-admin-key: ${API_ADMIN_KEY}" \
        "$@"
}

api_get() {
    local path="$1"
    api_request "GET" "$path"
}

api_post() {
    local path="$1"
    api_request "POST" "$path"
}

highest_alert_created_at() {
    jq -r '
        if type == "array" and length > 0 then
            (map(.created_at // "") | max)
        else
            ""
        end
    '
}

ensure_summary_json() {
    jq -n \
        --arg status "$RUN_STATUS" \
        --arg started_at "$STARTED_AT" \
        --arg finished_at "$FINISHED_AT" \
        --arg reason "$SUMMARY_REASON" \
        --arg target_region "$TARGET_REGION" \
        --arg tenant_id "$TENANT_ID" \
        --arg primary_vm_id "$PRIMARY_VM_ID" \
        --arg replica_vm_id "$REPLICA_VM_ID" \
        --arg artifact_dir "$ARTIFACT_DIR" \
        --argjson cycle_interval_secs "$CYCLE_INTERVAL_SECS" \
        --argjson unhealthy_threshold "$UNHEALTHY_THRESHOLD" \
        --argjson recovery_threshold "$RECOVERY_THRESHOLD" \
        --argjson detect_timeout_secs "$DETECT_TIMEOUT_SECS" \
        --argjson recovery_timeout_secs "$RECOVERY_TIMEOUT_SECS" \
        --argjson poll_interval_secs "$ALERT_POLL_INTERVAL_SECS" \
        '{
            status: $status,
            started_at: $started_at,
            finished_at: $finished_at,
            reason: $reason,
            target: {
                region: $target_region,
                tenant_id: $tenant_id,
                primary_vm_id: $primary_vm_id,
                replica_vm_id: $replica_vm_id
            },
            polling: {
                cycle_interval_secs: $cycle_interval_secs,
                unhealthy_threshold: $unhealthy_threshold,
                recovery_threshold: $recovery_threshold,
                detect_timeout_secs: $detect_timeout_secs,
                recovery_timeout_secs: $recovery_timeout_secs,
                poll_interval_secs: $poll_interval_secs
            },
            artifacts_dir: $artifact_dir
        }' > "$ARTIFACT_DIR/summary.json"
}

ensure_summary_md() {
    cat > "$ARTIFACT_DIR/summary.md" <<EOF_MD
# HA Failover Proof

- status: ${RUN_STATUS}
- started_at: ${STARTED_AT}
- finished_at: ${FINISHED_AT}
- target_region: ${TARGET_REGION}
- tenant_id: ${TENANT_ID}
- primary_vm_id: ${PRIMARY_VM_ID}
- replica_vm_id: ${REPLICA_VM_ID}
- detect_timeout_secs: ${DETECT_TIMEOUT_SECS}
- recovery_timeout_secs: ${RECOVERY_TIMEOUT_SECS}
- reason: ${SUMMARY_REASON}
- artifacts_dir: ${ARTIFACT_DIR}
EOF_MD
}

finalize_failure() {
    local message="$1"
    SUMMARY_REASON="$message"
    RUN_STATUS="failed"
    FINISHED_AT="$(iso_utc_now)"
    ensure_summary_json
    ensure_summary_md
    error "$message"
    exit 1
}

finalize_success() {
    local message="$1"
    SUMMARY_REASON="$message"
    RUN_STATUS="passed"
    FINISHED_AT="$(iso_utc_now)"
    ensure_summary_json
    ensure_summary_md
    log "$message"
}

# jq filters for alert polling — $baseline, $region, $tenant bound via --arg
FAILOVER_DETECTED_FILTER='
    (if type == "array" then . else [] end
     | map(select($baseline == "" or (.created_at // "") > $baseline))) as $new
    | ($new | any(.[];
        ((.title // "") | contains("Region down")) and
        (((.title // "") | contains($region)) or ((.message // "") | contains($region)))
      ))
    and
      ($new | any(.[];
        ((.title // "") | contains("Index failed over")) and
        (((.title // "") | contains($tenant)) or ((.message // "") | contains($tenant)))
      ))'

RECOVERY_DETECTED_FILTER='
    (if type == "array" then . else [] end
     | map(select($baseline == "" or (.created_at // "") > $baseline))) as $new
    | $new
    | any(.[];
        ((.title // "") | contains("Region recovered")) and
        (((.title // "") | contains($region)) or ((.message // "") | contains($region)))
      )'

poll_alerts_until() {
    local jq_filter="$1"
    local timeout_secs="$2"
    local baseline_created_at="$3"
    local elapsed=0
    local alerts_json

    while [ "$elapsed" -lt "$timeout_secs" ]; do
        if ! alerts_json="$(api_get "/admin/alerts")"; then
            error "Failed to read alerts during polling"
            return 1
        fi

        if printf '%s' "$alerts_json" | jq -e \
            --arg baseline "$baseline_created_at" \
            --arg region "$TARGET_REGION" \
            --arg tenant "$TENANT_ID" \
            "$jq_filter" >/dev/null 2>&1; then
            printf '%s\n' "$alerts_json"
            return 0
        fi

        sleep "$ALERT_POLL_INTERVAL_SECS"
        elapsed=$((elapsed + ALERT_POLL_INTERVAL_SECS))
    done

    return 1
}

if [ "$#" -lt 1 ]; then
    usage
    exit 1
fi

TARGET_REGION="$1"
require_command jq
require_command curl

load_env_file "$REPO_ROOT/.env.local"
API_URL="${API_URL:-http://localhost:3001}"
FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"
# API server authenticates against ADMIN_KEY, not FLAPJACK_ADMIN_KEY.
# FLAPJACK_ADMIN_KEY is still exported to kill/restart subscripts for flapjack calls.
API_ADMIN_KEY="${ADMIN_KEY:-$FLAPJACK_ADMIN_KEY}"

if ! is_loopback_api_base_url "$API_URL"; then
    error "API_URL must be a loopback http(s) base URL for local HA proof: $API_URL"
    exit 1
fi

CYCLE_INTERVAL_SECS="$(resolve_positive_int "${REGION_FAILOVER_CYCLE_INTERVAL_SECS:-60}" 60)"
UNHEALTHY_THRESHOLD="$(resolve_positive_int "${REGION_FAILOVER_UNHEALTHY_THRESHOLD:-3}" 3)"
RECOVERY_THRESHOLD="$(resolve_positive_int "${REGION_FAILOVER_RECOVERY_THRESHOLD:-2}" 2)"
DETECT_TIMEOUT_SECS="$(at_least "$((CYCLE_INTERVAL_SECS * UNHEALTHY_THRESHOLD * 2))" 10)"
RECOVERY_TIMEOUT_SECS="$(at_least "$((CYCLE_INTERVAL_SECS * RECOVERY_THRESHOLD * 2))" 10)"
ALERT_POLL_INTERVAL_SECS=$((CYCLE_INTERVAL_SECS / 6))
if [ "$ALERT_POLL_INTERVAL_SECS" -lt 1 ]; then
    ALERT_POLL_INTERVAL_SECS=1
fi

RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")-${TARGET_REGION}-$$"
ARTIFACT_DIR="/tmp/fjcloud-ha-proof/${RUN_ID}"
mkdir -p "$ARTIFACT_DIR"

RUN_STATUS="running"
SUMMARY_REASON=""
STARTED_AT="$(iso_utc_now)"
FINISHED_AT=""
TENANT_ID=""
PRIMARY_VM_ID=""
REPLICA_VM_ID=""

log "Starting HA failover proof for region ${TARGET_REGION}"

if ! curl -sf "${API_URL}/health" >/dev/null 2>&1; then
    finalize_failure "API health check failed at ${API_URL}/health"
fi

if ! VM_INVENTORY_BEFORE_JSON="$(api_get "/admin/vms")"; then
    finalize_failure "Failed to fetch VM inventory before failover run"
fi
printf '%s\n' "$VM_INVENTORY_BEFORE_JSON" > "$ARTIFACT_DIR/vm_inventory_before.json"

if ! REPLICAS_ACTIVE_JSON="$(api_get "/admin/replicas?status=active")"; then
    finalize_failure "Failed to fetch active replicas for failover candidate selection"
fi

CANDIDATE_JSON="$(
    printf '%s' "$REPLICAS_ACTIVE_JSON" | jq -c --arg region "$TARGET_REGION" '
        if type == "array" then . else [] end
        | map(select(.primary_vm_region == $region and .replica_region != $region))
        # RegionFailoverMonitor promotes the lowest-lag active replica, so the
        # proof helper must preselect the same target before it verifies
        # post-recovery tenant placement on the promoted VM.
        | sort_by(.tenant_id, .primary_vm_id, .lag_ops, .replica_vm_id)
        | .[0] // empty
    '
)"

# Repeatability preflight: when no active candidates exist, check whether replicas
# are suspended/consumed from a prior failover run rather than truly absent.
# Back-to-back proof runs hit this when the previous run's failover left replicas
# in suspended state — the generic "no candidate" error obscures the real cause.
if [ -z "$CANDIDATE_JSON" ]; then
    if ALL_REPLICAS_JSON="$(api_get "/admin/replicas")"; then
        SUSPENDED_IN_REGION="$(printf '%s' "$ALL_REPLICAS_JSON" | jq -c --arg region "$TARGET_REGION" '
            if type == "array" then . else [] end
            | map(select(.primary_vm_region == $region and .status == "suspended"))
        ')"
        if [ "$(printf '%s' "$SUSPENDED_IN_REGION" | jq 'length')" -gt 0 ]; then
            finalize_failure "Region ${TARGET_REGION} has consumed/suspended replicas from a prior failover run — clean up before re-running"
        fi
    fi
    finalize_failure "No valid failover candidate found for region ${TARGET_REGION}"
fi

TENANT_ID="$(printf '%s' "$CANDIDATE_JSON" | jq -r '.tenant_id // empty')"
PRIMARY_VM_ID="$(printf '%s' "$CANDIDATE_JSON" | jq -r '.primary_vm_id // empty')"
REPLICA_VM_ID="$(printf '%s' "$CANDIDATE_JSON" | jq -r '.replica_vm_id // empty')"
if [ -z "$TENANT_ID" ] || [ -z "$PRIMARY_VM_ID" ] || [ -z "$REPLICA_VM_ID" ]; then
    finalize_failure "Selected failover candidate is missing required identifiers"
fi

if ! ALERTS_BEFORE_JSON="$(api_get "/admin/alerts")"; then
    finalize_failure "Failed to fetch baseline alerts"
fi
printf '%s\n' "$ALERTS_BEFORE_JSON" > "$ARTIFACT_DIR/alerts_before.json"
BASELINE_ALERT_CURSOR="$(printf '%s' "$ALERTS_BEFORE_JSON" | highest_alert_created_at)"

# Baseline failover alerts are valid after a previous successful local proof.
# Polling below is cursor-based, so only alerts created after BASELINE_ALERT_CURSOR
# can satisfy this run. That keeps reruns repeatable without deleting operator
# evidence or relying on manual alert cleanup.

if ! TENANT_ASSIGNMENT_BEFORE_JSON="$(api_get "/admin/vms/${PRIMARY_VM_ID}")"; then
    finalize_failure "Failed to fetch tenant assignment from primary VM ${PRIMARY_VM_ID}"
fi
printf '%s\n' "$TENANT_ASSIGNMENT_BEFORE_JSON" > "$ARTIFACT_DIR/tenant_assignment_before.json"

FLAPJACK_DEV_DIR="$(resolve_default_flapjack_dev_dir)"
FLAPJACK_BIN="$(find_restart_ready_flapjack_binary || true)"
if [ -z "$FLAPJACK_BIN" ] || [ ! -x "$FLAPJACK_BIN" ]; then
    finalize_failure "Flapjack binary not found in configured candidates or PATH"
fi

log "Killing primary VM ${PRIMARY_VM_ID} in ${TARGET_REGION}"
if ! api_post "/admin/vms/${PRIMARY_VM_ID}/kill" >/dev/null; then
    finalize_failure "Failed to kill primary VM ${PRIMARY_VM_ID}"
fi

if ! ALERTS_AFTER_KILL_JSON="$(poll_alerts_until "$FAILOVER_DETECTED_FILTER" "$DETECT_TIMEOUT_SECS" "$BASELINE_ALERT_CURSOR")"; then
    finalize_failure "Timed out after ${DETECT_TIMEOUT_SECS}s waiting for failover alerts"
fi
printf '%s\n' "$ALERTS_AFTER_KILL_JSON" > "$ARTIFACT_DIR/alerts_after_kill.json"

log "Restarting region ${TARGET_REGION}"
if ! bash "$REPO_ROOT/scripts/chaos/restart-region.sh" "$TARGET_REGION"; then
    finalize_failure "Region restart failed for ${TARGET_REGION}"
fi

RECOVERY_ALERT_CURSOR="$(printf '%s' "$ALERTS_AFTER_KILL_JSON" | highest_alert_created_at)"
if ! ALERTS_AFTER_RECOVERY_JSON="$(poll_alerts_until "$RECOVERY_DETECTED_FILTER" "$RECOVERY_TIMEOUT_SECS" "$RECOVERY_ALERT_CURSOR")"; then
    finalize_failure "Timed out after ${RECOVERY_TIMEOUT_SECS}s waiting for recovery alert"
fi
printf '%s\n' "$ALERTS_AFTER_RECOVERY_JSON" > "$ARTIFACT_DIR/alerts_after_recovery.json"

if ! VM_INVENTORY_AFTER_JSON="$(api_get "/admin/vms")"; then
    finalize_failure "Failed to fetch VM inventory after recovery"
fi
printf '%s\n' "$VM_INVENTORY_AFTER_JSON" > "$ARTIFACT_DIR/vm_inventory_after.json"

if ! TENANT_ASSIGNMENT_AFTER_JSON="$(api_get "/admin/vms/${REPLICA_VM_ID}")"; then
    finalize_failure "Failed to fetch tenant assignment from promoted VM ${REPLICA_VM_ID}"
fi
printf '%s\n' "$TENANT_ASSIGNMENT_AFTER_JSON" > "$ARTIFACT_DIR/tenant_assignment_after.json"

if ! printf '%s' "$TENANT_ASSIGNMENT_AFTER_JSON" | jq -e --arg tenant "$TENANT_ID" '
    (.tenants // [])
    | if type == "array" then any(.[]; (.tenant_id // "") == $tenant) else false end
' >/dev/null 2>&1; then
    finalize_failure "No-switchback verification failed: tenant ${TENANT_ID} is not assigned to promoted VM ${REPLICA_VM_ID}"
fi

finalize_success "Failover proof succeeded with no automatic switchback"
log "Artifacts written to ${ARTIFACT_DIR}"
