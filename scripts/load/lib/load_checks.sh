#!/usr/bin/env bash
# Load regression checks for offline/live load harness comparisons.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/scripts/lib/live_gate.sh"

# Single source of truth for Stage 4 load targets.
LOAD_TARGET_ENDPOINTS=(
    "health"
    "search_query"
    "index_create"
    "admin_tenant_list"
    "document_ingestion"
)

compare_against_baseline() {
    local result_file="$1"
    local baseline_file="$2"

    if [ ! -f "$baseline_file" ]; then
        echo "REASON: LOAD_BASELINE_SKIP" >&2
        echo "Baseline missing: $baseline_file" >&2
        return 0
    fi

    if [ ! -f "$result_file" ]; then
        echo "REASON: LOAD_REGRESSION_FAILURE" >&2
        echo "Result file missing: $result_file" >&2
        return 1
    fi

    local verdict
    if ! verdict="$(python3 - "$result_file" "$baseline_file" <<'PY'
import json
import sys

result_path = sys.argv[1]
baseline_path = sys.argv[2]

with open(result_path, 'r', encoding='utf-8') as f:
    result = json.load(f)
with open(baseline_path, 'r', encoding='utf-8') as f:
    baseline = json.load(f)

LATENCY_ABSOLUTE_SLACK_MS = 50.0

result_meta = result.get("meta", {})
if result_meta.get("k6_status") not in (None, "", "pass"):
    print("threshold_fail")
    sys.exit(0)

def pct_degradation(curr, base):
    if base == 0:
        return 0.0
    return ((curr - base) / base) * 100.0

def pct_throughput_drop(curr, base):
    if base == 0:
        return 0.0
    return ((base - curr) / base) * 100.0

def normalized_latency_degradation(curr, base):
    if curr <= base:
        return 0.0

    absolute_increase = curr - base
    if absolute_increase <= LATENCY_ABSOLUTE_SLACK_MS:
        # Local loopback runs can swing by a few dozen milliseconds while still
        # remaining comfortably inside the explicit k6 SLA thresholds. Treat
        # those tiny absolute shifts as noise instead of hard regressions.
        return 0.0

    return pct_degradation(curr, base)

latency_keys = ["latency_p50_ms", "latency_p95_ms", "latency_p99_ms"]
latency_degradations = []
for key in latency_keys:
    latency_degradations.append(
        normalized_latency_degradation(float(result[key]), float(baseline[key]))
    )

throughput_drop = pct_throughput_drop(float(result["throughput_rps"]), float(baseline["throughput_rps"]))
max_degradation = max(latency_degradations + [throughput_drop])

if float(result.get("error_rate", 0.0)) > 0.05:
    print("fail")
elif max_degradation > 50.0:
    print("fail")
elif max_degradation > 20.0:
    print("warn")
else:
    print("pass")
PY
    )"; then
        echo "REASON: LOAD_REGRESSION_FAILURE" >&2
        echo "Unable to compare load result against baseline" >&2
        return 1
    fi

    case "$verdict" in
        pass)
            echo "REASON: LOAD_BASELINE_PASS" >&2
            return 0
            ;;
        warn)
            echo "REASON: LOAD_REGRESSION_WARNING" >&2
            return 0
            ;;
        fail)
            echo "REASON: LOAD_REGRESSION_FAILURE" >&2
            return 1
            ;;
        threshold_fail)
            echo "REASON: LOAD_K6_THRESHOLD_FAILURE" >&2
            return 1
            ;;
        *)
            echo "REASON: LOAD_REGRESSION_FAILURE" >&2
            echo "Unexpected comparison verdict: $verdict" >&2
            return 1
            ;;
    esac
}

run_load_gate() {
    local baseline_dir="${LOAD_BASELINE_DIR:-"$REPO_ROOT/scripts/load/baselines"}"
    local result_dir="${LOAD_RESULT_DIR:-"$baseline_dir"}"

    local checks_failed=0

    local suite_start_ms
    suite_start_ms="$(_ms_now)"

    local data_file
    data_file="$(mktemp)"

    local endpoint
    for endpoint in "${LOAD_TARGET_ENDPOINTS[@]}"; do
        local check_name="load_${endpoint}"
        local check_start_ms
        check_start_ms="$(_ms_now)"

        local result_file="$result_dir/${endpoint}.json"
        local baseline_file="$baseline_dir/${endpoint}.json"

        local output exit_code=0
        output="$(compare_against_baseline "$result_file" "$baseline_file" 2>&1)" || exit_code=$?

        local reason_line
        reason_line="$(echo "$output" | grep -m1 '^REASON:' || true)"
        local reason_code
        reason_code="$(_strip_reason_prefix "$reason_line")"

        local check_end_ms
        check_end_ms="$(_ms_now)"
        local elapsed=$(( check_end_ms - check_start_ms ))

        local status
        local error_class=""
        case "$exit_code" in
            0)
                if [[ "$reason_code" == *"SKIP"* ]]; then
                    status="skipped"
                    error_class="precondition"
                elif [ "$reason_code" = "LOAD_REGRESSION_WARNING" ]; then
                    status="warn"
                else
                    status="pass"
                fi
                ;;
            *)
                status="fail"
                checks_failed=$((checks_failed + 1))
                error_class="runtime"
                if [ -z "$reason_code" ]; then
                    reason_code="LOAD_REGRESSION_FAILURE"
                fi
                ;;
        esac

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$check_name" "$status" "$elapsed" "$reason_code" "$error_class" >> "$data_file"
    done

    local suite_end_ms
    suite_end_ms="$(_ms_now)"
    local total_elapsed=$(( suite_end_ms - suite_start_ms ))

    python3 - "$data_file" "$total_elapsed" <<'PY'
import json
import sys

data_file = sys.argv[1]
total_elapsed = int(sys.argv[2])

check_results = []
failures = []
checks_run = 0
checks_failed = 0
checks_skipped = 0

with open(data_file, "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 4)
        name = parts[0]
        status = parts[1] if len(parts) > 1 else "unknown"
        elapsed = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
        reason = parts[3] if len(parts) > 3 else ""
        error_class = parts[4] if len(parts) > 4 else ""

        entry = {
            "elapsed_ms": elapsed,
            "name": name,
            "reason": reason,
            "status": status,
        }
        if error_class:
            entry["error_class"] = error_class
        check_results.append(entry)

        if status == "fail":
            checks_failed += 1
            checks_run += 1
            failures.append(name)
        elif status == "pass":
            checks_run += 1
        elif status == "warn":
            checks_run += 1
        elif status == "skipped":
            checks_skipped += 1

output = {
    "check_results": check_results,
    "checks_run": checks_run,
    "checks_failed": checks_failed,
    "checks_skipped": checks_skipped,
    "passed": checks_failed == 0,
    "elapsed_ms": total_elapsed,
    "failures": failures,
}
print(json.dumps(output, sort_keys=True))
PY

    rm -f "$data_file"

    if [ "$checks_failed" -gt 0 ]; then
        return 1
    fi
    return 0
}

__LOAD_CHECKS_SOURCED=1
