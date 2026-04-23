#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/live_gate.sh"
source "$REPO_ROOT/ops/scripts/lib/deploy_validation.sh"

LAUNCH_GATE_SHA=""
LAUNCH_GATE_ENV="staging"

declare -a _GATE_NAMES=()
declare -a _GATE_STATUSES=()
declare -a _GATE_REASONS=()
declare -a _GATE_DURATIONS=()
declare -a _GATE_CHECKS_RUN=()

print_usage() {
    cat <<'USAGE' >&2
Usage:
  backend_launch_gate.sh --sha=<GIT_SHA> [--env=<ENV>]
  backend_launch_gate.sh --help
USAGE
}

_is_valid_json() {
    local value="$1"
    python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$value" >/dev/null 2>&1
}

_gate_passed_from_json() {
    local output_json="$1"
    python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
print("true" if data.get("passed") is True else "false")
' <<< "$output_json"
}

_gate_reason_from_json() {
    local output_json="$1"
    python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
failures = data.get("failures", [])
if isinstance(failures, list) and failures:
    print(", ".join(str(item) for item in failures))
else:
    reason = data.get("reason", "")
    print("" if reason is None else str(reason))
' <<< "$output_json"
}

_gate_checks_run_from_json() {
    local output_json="$1"
    python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
val = data.get("checks_run", 0)
try:
    print(int(val))
except Exception:
    print(0)
' <<< "$output_json"
}

_run_sub_gate() {
    local name="$1"
    local command="$2"

    local start_ms end_ms duration_ms
    start_ms="$(_ms_now)"

    local output="" exit_code=0
    if [[ ! "$command" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        exit_code=127
    else
        output="$("$command")" || exit_code=$?
    fi

    end_ms="$(_ms_now)"
    duration_ms=$((end_ms - start_ms))

    local status="pass"
    local reason=""
    local checks_run="0"

    if [ -z "$output" ] || ! _is_valid_json "$output"; then
        status="fail"
        reason="sub-gate produced no output"
    else
        local passed
        passed="$(_gate_passed_from_json "$output")"
        reason="$(_gate_reason_from_json "$output")"
        checks_run="$(_gate_checks_run_from_json "$output")"

        if [ "$passed" != "true" ] || [ "$exit_code" -ne 0 ]; then
            status="fail"
            if [ -z "$reason" ]; then
                reason="sub-gate failed"
            fi
        else
            status="pass"
        fi
    fi

    _GATE_NAMES+=("$name")
    _GATE_STATUSES+=("$status")
    _GATE_REASONS+=("$reason")
    _GATE_DURATIONS+=("$duration_ms")
    _GATE_CHECKS_RUN+=("$checks_run")
}

_invoke_reliability_gate() {
    bash "$REPO_ROOT/scripts/reliability/run_backend_reliability_gate.sh" --reliability-only
}

_invoke_security_gate() {
    bash "$REPO_ROOT/scripts/reliability/run_backend_reliability_gate.sh" --security-only
}

_invoke_load_gate() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        cat <<'JSON'
{"passed": true, "failures": [], "checks_run": 0, "checks_failed": 0, "elapsed_ms": 0, "reason": "dry_run — load gate skipped"}
JSON
        return 0
    fi
    bash "$REPO_ROOT/scripts/reliability/run_backend_reliability_gate.sh" --load-only
}

_invoke_commerce_gate() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        local commerce_json commerce_exit=0
        commerce_json="$(BACKEND_LIVE_GATE=0 bash "$REPO_ROOT/scripts/live-backend-gate.sh" --skip-rust-tests)" || commerce_exit=$?
        python3 -c '
import json,sys
data=json.loads(sys.stdin.read())
base_reason=data.get("reason","")
if base_reason:
    data["reason"]=f"dry_run — {base_reason}"
else:
    data["reason"]="dry_run — external commerce checks skipped/soft-validated"
print(json.dumps(data, sort_keys=True))
' <<< "$commerce_json"
        return "$commerce_exit"
    fi
    bash "$REPO_ROOT/scripts/live-backend-gate.sh" --skip-rust-tests
}

_invoke_ci_cd_gate() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        cat <<'JSON'
{"passed": true, "failures": [], "checks_run": 0, "checks_failed": 0, "elapsed_ms": 0, "reason": "dry_run — CI status check skipped"}
JSON
        return 0
    fi

    local status_code=0
    local ci_output=""
    ci_output="$(ci_status_is_passing "$LAUNCH_GATE_SHA" 2>&1)" || status_code=$?
    if [ -n "$ci_output" ]; then
        echo "$ci_output" >&2
    fi

    case "$status_code" in
        0)
            cat <<JSON
{"passed": true, "failures": [], "checks_run": 1, "checks_failed": 0, "elapsed_ms": 0, "reason": ""}
JSON
            return 0
            ;;
        1)
            cat <<JSON
{"passed": false, "failures": ["CI status not passing for SHA $LAUNCH_GATE_SHA"], "checks_run": 1, "checks_failed": 1, "elapsed_ms": 0, "reason": "CI status not passing for SHA $LAUNCH_GATE_SHA"}
JSON
            return 1
            ;;
        *)
            cat <<JSON
{"passed": false, "failures": ["CI status lookup error"], "checks_run": 1, "checks_failed": 1, "elapsed_ms": 0, "reason": "CI status lookup error"}
JSON
            return 1
            ;;
    esac
}

_build_verdict_json() {
    GATE_NAMES="$(printf '%s\x1f' "${_GATE_NAMES[@]}")" \
    GATE_STATUSES="$(printf '%s\x1f' "${_GATE_STATUSES[@]}")" \
    GATE_REASONS="$(printf '%s\x1f' "${_GATE_REASONS[@]}")" \
    GATE_DURATIONS="$(printf '%s\x1f' "${_GATE_DURATIONS[@]}")" \
    GATE_CHECKS_RUN="$(printf '%s\x1f' "${_GATE_CHECKS_RUN[@]}")" \
    python3 -c '
import json
import os
from datetime import datetime, timezone

def decode_list(key):
    raw = os.environ.get(key, "")
    if raw == "":
        return []
    parts = raw.split("\x1f")
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return parts

names = decode_list("GATE_NAMES")
statuses = decode_list("GATE_STATUSES")
reasons = decode_list("GATE_REASONS")
durations = decode_list("GATE_DURATIONS")
checks_run_values = decode_list("GATE_CHECKS_RUN")

gates = []
for i, name in enumerate(names):
    status = statuses[i] if i < len(statuses) else "fail"
    reason = reasons[i] if i < len(reasons) else "sub-gate result missing"
    duration_raw = durations[i] if i < len(durations) else "0"
    checks_run_raw = checks_run_values[i] if i < len(checks_run_values) else "0"
    try:
        duration = int(duration_raw)
    except Exception:
        duration = 0
    try:
        checks_run = int(checks_run_raw)
    except Exception:
        checks_run = 0
    gates.append({
        "checks_run": checks_run,
        "name": name,
        "status": status,
        "reason": reason,
        "duration_ms": duration,
    })

verdict = "fail" if any(g.get("status") == "fail" for g in gates) else "pass"
timestamp = datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps({"verdict": verdict, "timestamp": timestamp, "gates": gates}, sort_keys=True))
'
}

_archive_evidence() {
    local verdict_json="$1"
    local evidence_dir="${LAUNCH_GATE_EVIDENCE_DIR:-$REPO_ROOT/docs/launch/evidence}"
    mkdir -p "$evidence_dir"

    local evidence_path
    while true; do
        evidence_path="$evidence_dir/backend_gate_$(date +%Y-%m-%d_%H%M%S).json"
        if [ ! -e "$evidence_path" ]; then
            break
        fi
        sleep 1
    done

    printf '%s\n' "$verdict_json" > "$evidence_path"
    echo "[evidence] Archived to: $evidence_path" >&2
}

run_backend_launch_gate() {
    LAUNCH_GATE_SHA=""
    LAUNCH_GATE_ENV="staging"

    local arg
    for arg in "$@"; do
        case "$arg" in
            --sha=*)
                LAUNCH_GATE_SHA="${arg#--sha=}"
                ;;
            --env=*)
                LAUNCH_GATE_ENV="${arg#--env=}"
                ;;
            --help)
                print_usage
                return 0
                ;;
            *)
                echo "ERROR: unknown argument '$arg'" >&2
                print_usage
                return 2
                ;;
        esac
    done

    if [ -z "$LAUNCH_GATE_SHA" ]; then
        echo "ERROR: --sha is required" >&2
        print_usage
        return 2
    fi

    if [[ ! "$LAUNCH_GATE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        echo "ERROR: --sha must be a 40-character lowercase hexadecimal commit SHA" >&2
        return 2
    fi

    _GATE_NAMES=()
    _GATE_STATUSES=()
    _GATE_REASONS=()
    _GATE_DURATIONS=()
    _GATE_CHECKS_RUN=()

    _run_sub_gate "reliability" "_invoke_reliability_gate"
    _run_sub_gate "security" "_invoke_security_gate"
    _run_sub_gate "commerce" "_invoke_commerce_gate"
    _run_sub_gate "load" "_invoke_load_gate"
    _run_sub_gate "ci_cd" "_invoke_ci_cd_gate"

    local verdict_json
    verdict_json="$(_build_verdict_json)"
    printf '%s\n' "$verdict_json"

    _archive_evidence "$verdict_json"

    if python3 -c 'import json,sys; raise SystemExit(0 if json.loads(sys.stdin.read()).get("verdict") == "pass" else 1)' <<< "$verdict_json"; then
        return 0
    fi
    return 1
}

if [[ "${__BACKEND_LAUNCH_GATE_SOURCED:-0}" != "1" ]]; then
    run_backend_launch_gate "$@"
fi
