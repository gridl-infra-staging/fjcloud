#!/usr/bin/env bash

# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
# TODO: Document parse_delegated_billing_summary.
parse_delegated_billing_summary() {
    local json_body="$1"
    DELEGATED_JSON_RESULT=""
    DELEGATED_JSON_CLASSIFICATION=""
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi
    local parsed_result="" parsed_classification="" parsed_line="" parsed_index=0
    while IFS= read -r parsed_line; do
        if [ "$parsed_index" -eq 0 ]; then
            parsed_result="$parsed_line"
        elif [ "$parsed_index" -eq 1 ]; then
            parsed_classification="$parsed_line"
        fi
        parsed_index=$((parsed_index + 1))
    done < <(
        python3 - "$json_body" <<'PY' 2>/dev/null || true
import json
import sys
body = sys.argv[1]
try:
    payload = json.loads(body)
except Exception:
    print("")
    print("")
    raise SystemExit(0)
result = payload.get("result", "")
classification = payload.get("classification", "")
print("" if result is None else str(result))
print("" if classification is None else str(classification))
PY
    )
    DELEGATED_JSON_RESULT="$parsed_result"
    DELEGATED_JSON_CLASSIFICATION="$parsed_classification"
}

emit_result_json() {
    local verdict="$1"
    local mode="$2"
    local start_ms="$3"
    local ready="$4"
    local end_ms total_elapsed
    end_ms="$(_ms_now)"
    total_elapsed=$((end_ms - start_ms))
    local names_encoded statuses_encoded reasons_encoded elapsed_encoded preflight_encoded=""
    names_encoded="$(printf '%s\x1f' "${STEP_NAMES[@]:-}")"
    statuses_encoded="$(printf '%s\x1f' "${STEP_STATUSES[@]:-}")"
    reasons_encoded="$(printf '%s\x1f' "${STEP_REASONS[@]:-}")"
    elapsed_encoded="$(printf '%s\x1f' "${STEP_ELAPSED_MS[@]:-}")"
    if [ "${#PRE_FLIGHT_FAILURES[@]}" -gt 0 ]; then
        preflight_encoded="$(printf '%s\x1f' "${PRE_FLIGHT_FAILURES[@]}")"
    fi
    NAMES="$names_encoded" \
    STATUSES="$statuses_encoded" \
    REASONS="$reasons_encoded" \
    ELAPSED="$elapsed_encoded" \
    PREFLIGHT="$preflight_encoded" \
    VERDICT="$verdict" \
    MODE="$mode" \
    TOTAL_ELAPSED="$total_elapsed" \
    READY="$ready" \
    python3 -c '
import json
import os
from datetime import datetime, timezone
def decode(key):
    raw = os.environ.get(key, "")
    if raw == "":
        return []
    parts = raw.split("\x1f")
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return parts
names = decode("NAMES")
statuses = decode("STATUSES")
reasons = decode("REASONS")
elapsed = decode("ELAPSED")
preflight_failures = decode("PREFLIGHT")
steps = []
for idx, name in enumerate(names):
    status = statuses[idx] if idx < len(statuses) else "fail"
    reason = reasons[idx] if idx < len(reasons) else ""
    elapsed_raw = elapsed[idx] if idx < len(elapsed) else "0"
    try:
        elapsed_ms = int(elapsed_raw)
    except Exception:
        elapsed_ms = 0
    steps.append({
        "name": name,
        "status": status,
        "reason": reason,
        "elapsed_ms": elapsed_ms,
    })
ts = datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
verdict = os.environ.get("VERDICT", "fail")
ready = os.environ.get("READY", "false").lower() == "true"
for step in steps:
    status = step.get("status", "")
    if status in {"fail", "live_evidence_gap", "external_secret_missing"}:
        verdict = "fail"
        ready = False
        break
obj = {
    "elapsed_ms": int(os.environ.get("TOTAL_ELAPSED", "0")),
    "mode": os.environ.get("MODE", "live"),
    "ready": ready,
    "steps": steps,
    "timestamp": ts,
    "verdict": verdict,
}
if preflight_failures:
    obj["preflight_failures"] = preflight_failures
print(json.dumps(obj, sort_keys=True))
'
}

backend_gate_reason_from_json() {
    local payload="$1"
    python3 -c '
import json,sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    print("backend launch gate returned invalid JSON")
    raise SystemExit(0)
if data.get("verdict") == "pass":
    print("")
else:
    gates = data.get("gates", [])
    if isinstance(gates, list):
        failures = []
        for gate in gates:
            if isinstance(gate, dict) and gate.get("status") == "fail":
                name = gate.get("name", "unknown")
                reason = gate.get("reason", "")
                failures.append(f"{name}: {reason}" if reason else str(name))
        if failures:
            print("; ".join(failures))
            raise SystemExit(0)
    print(str(data.get("reason", "backend launch gate failed")))
' <<< "$payload"
}
