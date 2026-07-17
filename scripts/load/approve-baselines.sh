#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/load/run_load_harness.sh"

log() { echo "[load-approve] $*" >&2; }
die() { echo "[load-approve] ERROR: $*" >&2; exit 1; }

ARTIFACT_ROOT="${LOAD_APPROVAL_ARTIFACT_ROOT:-$REPO_ROOT/tmp/load-baselines}"
RUN_ID="${LOAD_APPROVAL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
ARTIFACT_DIR="$ARTIFACT_ROOT/$RUN_ID"
BASELINE_DIR="${LOAD_BASELINE_DIR:-$REPO_ROOT/scripts/load/baselines}"
export LOAD_PREPARE_LOCAL="${LOAD_PREPARE_LOCAL:-1}"
export LOAD_RESET_LOCAL_BETWEEN_ENDPOINTS="${LOAD_RESET_LOCAL_BETWEEN_ENDPOINTS:-1}"

approval_profile="${LOAD_APPROVAL_PROFILE:-local_fixed}"
if ! apply_k6_profile_defaults "$approval_profile"; then
    die "unsupported LOAD_APPROVAL_PROFILE: ${approval_profile}"
fi

mkdir -p "$ARTIFACT_DIR"
mkdir -p "$BASELINE_DIR"

if ! command -v k6 >/dev/null 2>&1; then
    die "k6 is required to approve baselines"
fi

if [ "$LOAD_PREPARE_LOCAL" = "1" ]; then
    log "Preparing dedicated local load user/index"
    if ! prepare_local_live_env_if_requested; then
        die "local load preparation failed"
    fi
fi

if ! ensure_live_env_prereqs; then
    die "live load environment is incomplete; ensure JWT, INDEX_NAME, and ADMIN_KEY are set"
fi

k6_mode="$(_resolve_k6_mode)" || die "invalid LOAD_K6_MODE"
concurrency=""
duration_sec=""
if [ "$k6_mode" = "fixed" ]; then
    concurrency="${LOAD_K6_CONCURRENCY:-1}"
    duration_sec="${LOAD_K6_DURATION_SEC:-30}"
    log "Capturing fixed local baselines with --vus ${concurrency} --duration ${duration_sec}s"
else
    log "Capturing script-owned staged baselines"
fi
if [ "$LOAD_RESET_LOCAL_BETWEEN_ENDPOINTS" = "1" ]; then
    log "Resetting dedicated local load setup between endpoint workloads"
fi

log "Writing captured summaries and result JSON to $ARTIFACT_DIR"
run_live_workload_into_dir "$ARTIFACT_DIR" "$k6_mode" "$concurrency" "$duration_sec" || die "live workload execution failed"

python3 - "$ARTIFACT_DIR" "$BASELINE_DIR" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

artifact_dir = Path(sys.argv[1])
baseline_dir = Path(sys.argv[2])
approved_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

result_files = sorted(
    path for path in artifact_dir.glob("*.json")
    if not path.name.endswith("_summary.json")
)
if not result_files:
    raise SystemExit("no load result JSON files were captured")

threshold_failures = []
approved_endpoints = []

for result_path in result_files:
    with result_path.open("r", encoding="utf-8") as fh:
        result = json.load(fh)

    endpoint = result.get("endpoint", result_path.stem)
    meta = dict(result.get("meta", {}))
    k6_status = meta.get("k6_status", "pass")
    if k6_status != "pass":
        threshold_failures.append(f"{endpoint}:{k6_status}")
        continue

    meta.update({
        "source": "approved_local",
        "approved_at": approved_at,
        "approval_script": "scripts/load/approve-baselines.sh",
        "artifact_dir": str(artifact_dir),
        "summary_file": str(artifact_dir / f"{endpoint}_summary.json"),
        "notes": "approved local load baseline captured from a live local stack run",
    })
    result["meta"] = meta

    baseline_path = baseline_dir / f"{endpoint}.json"
    with baseline_path.open("w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2, sort_keys=True)
        fh.write("\n")
    approved_endpoints.append(endpoint)

if threshold_failures:
    raise SystemExit(
        "refusing baseline approval because k6 script thresholds failed for: "
        + ", ".join(threshold_failures)
    )

print(json.dumps({
    "approved_at": approved_at,
    "artifact_dir": str(artifact_dir),
    "approved_endpoints": approved_endpoints,
}, sort_keys=True))
PY
