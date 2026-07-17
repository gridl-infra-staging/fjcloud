#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
LOAD_TESTS_DIR="$REPO_ROOT/tests/load"

source "$REPO_ROOT/scripts/load/lib/load_checks.sh"

LOAD_LIVE_FAILURE_REASON=""
LOAD_LIVE_FAILURE_CLASS=""

# Emit a single structured harness check result with the standard envelope.
emit_single_check_json() {
    local check_name="$1"
    local status="$2"
    local reason="$3"
    local error_class="$4"

    local start_ms
    start_ms="$(_ms_now)"
    local end_ms
    end_ms="$(_ms_now)"
    local elapsed=$(( end_ms - start_ms ))
    local checks_run=0
    local checks_failed=0
    local checks_skipped=0
    local passed=true
    local failure_name=""

    case "$status" in
        skipped)
            checks_skipped=1
            ;;
        fail)
            checks_run=1
            checks_failed=1
            passed=false
            failure_name="$check_name"
            ;;
        pass|warn)
            checks_run=1
            ;;
        *)
            echo "unsupported structured check status: $status" >&2
            return 1
            ;;
    esac

    python3 - "$check_name" "$status" "$reason" "$error_class" "$elapsed" "$checks_run" "$checks_failed" "$checks_skipped" "$passed" "$failure_name" <<'PY'
import json
import sys

check_name, status, reason, error_class, elapsed, checks_run, checks_failed, checks_skipped, passed, failure_name = sys.argv[1:]
payload = {
    "check_results": [
        {
            "name": check_name,
            "status": status,
            "reason": reason,
            "error_class": error_class,
            "elapsed_ms": int(elapsed),
        }
    ],
    "checks_run": int(checks_run),
    "checks_failed": int(checks_failed),
    "checks_skipped": int(checks_skipped),
    "passed": passed == "true",
    "elapsed_ms": int(elapsed),
    "failures": [failure_name] if failure_name else [],
}
print(json.dumps(payload, sort_keys=True))
PY
}

# Emit structured JSON indicating k6 was skipped (not installed).
# Allows the harness to report a clean skip without failing the gate.
emit_k6_skip_json() {
    emit_single_check_json \
        "load_k6_live_execution" \
        "skipped" \
        "LOAD_K6_SKIP_TOOL_MISSING" \
        "precondition"
}

# Emit structured JSON for a precondition failure (env setup, local prep, etc.).
# The reason code identifies which prerequisite was not satisfied.
emit_precondition_failure_json() {
    local reason="$1"
    emit_single_check_json "load_live_prerequisites" "fail" "$reason" "precondition"
}

# Emit structured JSON for a k6 runtime failure (crash, unexpected exit).
# Distinct from precondition failures — the workload started but did not complete.
emit_runtime_failure_json() {
    local reason="$1"
    emit_single_check_json "load_k6_live_execution" "fail" "$reason" "runtime"
}

record_live_failure() {
    LOAD_LIVE_FAILURE_REASON="$1"
    LOAD_LIVE_FAILURE_CLASS="$2"
}

prepare_local_live_env_if_requested() {
    if [ "${LOAD_PREPARE_LOCAL:-0}" != "1" ]; then
        return 0
    fi

    local prep_output
    if ! prep_output="$("$HARNESS_DIR/setup-local-prereqs.sh")"; then
        return 1
    fi

    eval "$prep_output"
}

# Guard that validates all required env vars (JWT, INDEX_NAME, ADMIN_KEY) are set
# before running live workloads. Fails fast with a list of missing vars.
ensure_live_env_prereqs() {
    local missing=()

    if [ -z "${JWT:-}" ]; then
        missing+=("JWT")
    fi

    if [ -z "${INDEX_NAME:-}" ]; then
        missing+=("INDEX_NAME")
    fi

    if [ -z "${ADMIN_KEY:-}" ]; then
        missing+=("ADMIN_KEY")
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "missing live load env prerequisites: ${missing[*]}" >&2
        return 1
    fi
}

apply_k6_profile_defaults() {
    local profile="$1"

    if [ -n "${LOAD_K6_MODE:-}" ] || [ -n "${LOAD_K6_CONCURRENCY:-}" ] || [ -n "${LOAD_K6_DURATION_SEC:-}" ]; then
        return 0
    fi

    case "$profile" in
        local_fixed)
            local local_fixed_concurrency="${LOAD_LOCAL_FIXED_CONCURRENCY:-${LOAD_APPROVAL_LOCAL_CONCURRENCY:-5}}"
            local local_fixed_duration_sec="${LOAD_LOCAL_FIXED_DURATION_SEC:-${LOAD_APPROVAL_LOCAL_DURATION_SEC:-45}}"
            export LOAD_K6_MODE="fixed"
            export LOAD_K6_CONCURRENCY="$local_fixed_concurrency"
            export LOAD_K6_DURATION_SEC="$local_fixed_duration_sec"
            export INDEX_CREATE_P95_MS="${INDEX_CREATE_P95_MS:-1600}"
            export LIST_INDEXES_P95_MS="${LIST_INDEXES_P95_MS:-300}"
            ;;
        staged)
            ;;
        *)
            echo "unsupported load profile: $profile" >&2
            return 1
            ;;
    esac
}

_k6_script_for_endpoint() {
    local endpoint="$1"
    case "$endpoint" in
        health) echo "$LOAD_TESTS_DIR/health.js" ;;
        search_query) echo "$LOAD_TESTS_DIR/search-query.js" ;;
        index_create) echo "$LOAD_TESTS_DIR/index-crud.js" ;;
        admin_tenant_list) echo "$LOAD_TESTS_DIR/admin-fleet.js" ;;
        document_ingestion) echo "$LOAD_TESTS_DIR/document-ingestion.js" ;;
        *) return 1 ;;
    esac
}

# Convert a raw k6 summary JSON into the normalized result format consumed by
# the load gate. Extracts latency percentiles, throughput, and error rate into
# a single per-endpoint result file that compare_against_baseline can evaluate.
_summary_to_result_json() {
    local summary_path="$1"
    local endpoint="$2"
    local out_path="$3"
    local concurrency="$4"
    local duration_sec="$5"
    local k6_mode="$6"
    local k6_exit_code="$7"

    python3 - "$summary_path" "$endpoint" "$out_path" "$concurrency" "$duration_sec" "$k6_mode" "$k6_exit_code" <<'PY'
import json
import sys
from datetime import datetime, timezone

summary_path, endpoint, out_path, requested_concurrency, requested_duration_sec, k6_mode, k6_exit_code = sys.argv[1:]

with open(summary_path, "r", encoding="utf-8") as f:
    summary = json.load(f)

metrics = summary.get("metrics", {})

def metric_values(name):
    metric = metrics.get(name, {})
    values = metric.get("values")
    if isinstance(values, dict):
        return values
    if isinstance(metric, dict):
        return metric
    return {}

def as_float(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default

def as_int(value, default=0):
    try:
        return int(round(float(value)))
    except (TypeError, ValueError):
        return default

def derive_duration_sec():
    for metric_name in ("iterations", "http_reqs"):
        values = metric_values(metric_name)
        count = as_float(values.get("count"))
        rate = as_float(values.get("rate"))
        if rate > 0:
            return max(1, int(round(count / rate)))
    return 0

def derive_concurrency():
    for metric_name in ("vus_max", "vus"):
        values = metric_values(metric_name)
        derived = as_int(values.get("value") if "value" in values else values.get("max"))
        if derived > 0:
            return derived
    return 0

dur = metric_values("http_req_duration")
reqs = metric_values("http_reqs")
failed = metric_values("http_req_failed")
k6_exit_code_int = as_int(k6_exit_code)

result_concurrency = as_int(requested_concurrency) if requested_concurrency else derive_concurrency()
result_duration_sec = as_int(requested_duration_sec) if requested_duration_sec else derive_duration_sec()

result = {
    "endpoint": endpoint,
    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "concurrency": result_concurrency,
    "duration_sec": result_duration_sec,
    "latency_p50_ms": as_float(dur.get("p(50)", dur.get("med", 0.0))),
    "latency_p95_ms": as_float(dur.get("p(95)", 0.0)),
    "latency_p99_ms": as_float(dur.get("p(99)", 0.0)),
    "throughput_rps": as_float(reqs.get("rate", 0.0)),
    "error_rate": as_float(failed.get("rate", failed.get("value", 0.0))),
    "meta": {
        "source": "k6_live",
        "summary_file": summary_path,
        "k6_mode": k6_mode,
        "k6_exit_code": k6_exit_code_int,
        "k6_status": (
            "pass" if k6_exit_code_int == 0
            else "threshold_fail" if k6_exit_code_int == 99
            else "runtime_fail"
        ),
    }
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2, sort_keys=True)
PY
}

# Determine k6 execution mode: "script" (k6 script controls VUs/duration) or
# "fixed" (harness overrides via LOAD_K6_CONCURRENCY / LOAD_K6_DURATION_SEC).
# Auto-selects "fixed" when either override env var is set.
_resolve_k6_mode() {
    local mode="${LOAD_K6_MODE:-}"
    if [ -z "$mode" ]; then
        if [ -n "${LOAD_K6_CONCURRENCY:-}" ] || [ -n "${LOAD_K6_DURATION_SEC:-}" ]; then
            mode="fixed"
        else
            mode="script"
        fi
    fi

    case "$mode" in
        script|fixed)
            printf '%s\n' "$mode"
            ;;
        *)
            echo "unsupported LOAD_K6_MODE: $mode" >&2
            return 1
            ;;
    esac
}

run_live_workload_into_dir() {
    local result_dir="$1"
    local k6_mode="$2"
    local concurrency="${3:-}"
    local duration_sec="${4:-}"
    local reset_between_endpoints="${LOAD_RESET_LOCAL_BETWEEN_ENDPOINTS:-0}"

    mkdir -p "$result_dir"
    record_live_failure "" ""

    local endpoint
    local first_endpoint=1
    for endpoint in "${LOAD_TARGET_ENDPOINTS[@]}"; do
        if [ "$first_endpoint" -eq 0 ] && [ "$reset_between_endpoints" = "1" ]; then
            if ! prepare_local_live_env_if_requested; then
                record_live_failure "LOAD_LOCAL_PREP_FAILURE" "precondition"
                echo "local load preparation reset failed before ${endpoint}" >&2
                return 1
            fi
            if ! ensure_live_env_prereqs; then
                record_live_failure "LOAD_LIVE_ENV_MISSING" "precondition"
                echo "live load environment became incomplete before ${endpoint}" >&2
                return 1
            fi
        fi
        first_endpoint=0

        local script_path
        script_path="$(_k6_script_for_endpoint "$endpoint")"
        local summary_file="$result_dir/${endpoint}_summary.json"
        local result_file="$result_dir/${endpoint}.json"
        local k6_exit_code=0
        local -a k6_args=(
            run
            --summary-export "$summary_file"
            --env "BASE_URL=${BASE_URL:-http://localhost:3001}"
            --env "JWT=${JWT:-}"
            --env "INDEX_NAME=${INDEX_NAME:-}"
            --env "ADMIN_KEY=${ADMIN_KEY:-}"
        )

        if [ "$k6_mode" = "fixed" ]; then
            k6_args+=(--vus "$concurrency" --duration "${duration_sec}s")
        fi

        k6_args+=("$script_path")

        k6 "${k6_args[@]}" >/dev/null || k6_exit_code=$?

        if [ ! -s "$summary_file" ]; then
            record_live_failure "LOAD_K6_RUNTIME_FAILURE" "runtime"
            echo "k6 did not export a summary for ${endpoint}" >&2
            return 1
        fi

        if [ "$k6_exit_code" -eq 99 ]; then
            echo "k6 thresholds failed for ${endpoint}; retaining exported summary for structured load verdicts" >&2
        elif [ "$k6_exit_code" -ne 0 ]; then
            record_live_failure "LOAD_K6_RUNTIME_FAILURE" "runtime"
            echo "k6 exited with unexpected status ${k6_exit_code} for ${endpoint}" >&2
            return 1
        fi

        if ! _summary_to_result_json \
            "$summary_file" \
            "$endpoint" \
            "$result_file" \
            "$concurrency" \
            "$duration_sec" \
            "$k6_mode" \
            "$k6_exit_code"; then
            record_live_failure "LOAD_K6_RUNTIME_FAILURE" "runtime"
            echo "failed to normalize k6 summary for ${endpoint}" >&2
            return 1
        fi
    done
}

run_live_mode() {
    if ! command -v k6 >/dev/null 2>&1; then
        emit_k6_skip_json
        return 0
    fi

    if ! prepare_local_live_env_if_requested; then
        emit_precondition_failure_json "LOAD_LOCAL_PREP_FAILURE"
        return 1
    fi

    if ! ensure_live_env_prereqs; then
        emit_precondition_failure_json "LOAD_LIVE_ENV_MISSING"
        return 1
    fi

    local baseline_dir="${LOAD_BASELINE_DIR:-"$REPO_ROOT/scripts/load/baselines"}"
    if ! apply_k6_profile_defaults "${LOAD_HARNESS_PROFILE:-local_fixed}"; then
        emit_precondition_failure_json "LOAD_K6_MODE_INVALID"
        return 1
    fi

    local k6_mode
    if ! k6_mode="$(_resolve_k6_mode)"; then
        emit_precondition_failure_json "LOAD_K6_MODE_INVALID"
        return 1
    fi

    local concurrency=""
    local duration_sec=""
    if [ "$k6_mode" = "fixed" ]; then
        duration_sec="${LOAD_K6_DURATION_SEC:-30}"
        concurrency="${LOAD_K6_CONCURRENCY:-1}"
    fi

    local result_dir="${LOAD_RESULT_DIR:-}"
    local cleanup_result_dir=0
    if [ -z "$result_dir" ]; then
        result_dir="$(mktemp -d)"
        cleanup_result_dir=1
    fi

    if ! run_live_workload_into_dir "$result_dir" "$k6_mode" "$concurrency" "$duration_sec"; then
        if [ "$cleanup_result_dir" -eq 1 ]; then
            rm -rf "$result_dir"
        fi
        case "${LOAD_LIVE_FAILURE_CLASS:-runtime}" in
            precondition)
                emit_precondition_failure_json "${LOAD_LIVE_FAILURE_REASON:-LOAD_LIVE_ENV_MISSING}"
                ;;
            *)
                emit_runtime_failure_json "${LOAD_LIVE_FAILURE_REASON:-LOAD_K6_RUNTIME_FAILURE}"
                ;;
        esac
        return 1
    fi

    local exit_code=0
    LOAD_BASELINE_DIR="$baseline_dir" LOAD_RESULT_DIR="$result_dir" run_load_gate || exit_code=$?

    if [ "$cleanup_result_dir" -eq 1 ]; then
        rm -rf "$result_dir"
    fi

    return "$exit_code"
}

main() {
    if [ "${LOAD_GATE_LIVE:-0}" = "1" ]; then
        run_live_mode
    else
        run_load_gate
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
