#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

COLLECT_SHA=""
COLLECT_EVIDENCE_DIR="${COLLECT_EVIDENCE_DIR:-$REPO_ROOT/docs/launch/evidence}"

print_usage() {
    cat <<'USAGE' >&2
Usage:
  collect_evidence.sh --sha=<GIT_SHA> [--evidence-dir=<DIR>]
  collect_evidence.sh --help
USAGE
}

_json_array_from_lines() {
    python3 -c 'import json,sys; rows=[]
for line in sys.stdin:
    line=line.strip()
    if line:
        rows.append(json.loads(line))
print(json.dumps(rows))'
}

_parse_pass_fail_from_test_output() {
    python3 -c 'import re,sys
passed=0
failed=0
for line in sys.stdin:
    m=re.search(r"test result:\s+\w+\.\s+(\d+) passed;\s+(\d+) failed;", line)
    if m:
        passed += int(m.group(1))
        failed += int(m.group(2))
print(f"{passed} {failed}")'
}

_json_name_counts_row() {
    local name="$1"
    local passed="$2"
    local failed="$3"

    NAME="$name" PASSED="$passed" FAILED="$failed" python3 -c 'import json,os
print(json.dumps({"name": os.environ["NAME"], "passed": int(os.environ["PASSED"]), "failed": int(os.environ["FAILED"])}))'
}

_json_skipped_row() {
    local name="$1"
    local reason="$2"

    NAME="$name" REASON="$reason" python3 -c 'import json,os
print(json.dumps({"name": os.environ["NAME"], "passed": 0, "failed": 0, "skipped": True, "reason": os.environ["REASON"]}))'
}

_run_cargo_test_for_crate() {
    local crate="$1"
    case "$crate" in
        api)
            cargo test -p "$crate" --lib
            ;;
        *)
            cargo test -p "$crate"
            ;;
    esac
}

_run_cargo_tests() {
    local crates=(api billing pricing-calculator metering-agent aggregation-job)
    local entries=""

    local crate
    for crate in "${crates[@]}"; do
        local output=""
        local exit_code=0
        if output="$(cd "$REPO_ROOT/infra" && _run_cargo_test_for_crate "$crate" 2>&1)"; then
            exit_code=0
        else
            exit_code=$?
        fi

        local counts=""
        counts="$(printf '%s\n' "$output" | _parse_pass_fail_from_test_output)"

        local passed="0"
        local failed="0"
        passed="${counts%% *}"
        failed="${counts##* }"

        if [ "$exit_code" -ne 0 ] && [ "$failed" -eq 0 ]; then
            failed=1
        fi

        local row_json
        row_json="$(_json_name_counts_row "$crate" "$passed" "$failed")"
        entries+="$row_json"$'\n'
    done

    printf '%s' "$entries" | _json_array_from_lines
}

_parse_suite_results_line() {
    python3 -c 'import re,sys
text=sys.stdin.read()
m=re.search(r"Results:\s*(\d+) passed,\s*(\d+) failed", text)
if not m:
    raise SystemExit(1)
print(f"{m.group(1)} {m.group(2)}")'
}

_is_dependency_source_failure() {
    local output="$1"
    if [[ "$output" == *"No such file or directory"* ]] || \
       [[ "$output" == *"command not found"* ]] || \
       [[ "$output" == *"failed to source"* ]] || \
       [[ "$output" == *"cannot open"* ]]; then
        return 0
    fi
    return 1
}

_run_shell_suites() {
    local entries=""
    local suite
    local matched_any=0
    local shell_tests_dir="${COLLECT_SHELL_TESTS_DIR:-$REPO_ROOT/scripts/tests}"

    for suite in "$shell_tests_dir"/*_test.sh; do
        if [ ! -e "$suite" ]; then
            continue
        fi
        matched_any=1

        local suite_name
        suite_name="$(basename "$suite")"

        local output=""
        local exit_code=0
        if output="$(bash "$suite" 2>&1)"; then
            exit_code=0
        else
            exit_code=$?
        fi

        local counts=""
        if counts="$(printf '%s' "$output" | _parse_suite_results_line 2>/dev/null)"; then
            local passed failed
            passed="${counts%% *}"
            failed="${counts##* }"

            local row_json
            row_json="$(_json_name_counts_row "$suite_name" "$passed" "$failed")"
            entries+="$row_json"$'\n'
        else
            local reason
            if [ "$exit_code" -ne 0 ]; then
                if _is_dependency_source_failure "$output"; then
                    reason="suite exited $exit_code before reporting results (dependency/source failure)"
                    local row_json
                    row_json="$(_json_skipped_row "$suite_name" "$reason")"
                    entries+="$row_json"$'\n'
                else
                    reason="suite exited $exit_code before reporting results"
                    local row_json
                    row_json="$(_json_name_counts_row "$suite_name" "0" "1")"
                    entries+="$row_json"$'\n'
                fi
            else
                reason="suite output did not contain pass/fail summary"
                local row_json
                row_json="$(_json_skipped_row "$suite_name" "$reason")"
                entries+="$row_json"$'\n'
            fi
        fi
    done

    if [ "$matched_any" -eq 0 ]; then
        printf '[]\n'
        return 0
    fi

    printf '%s' "$entries" | _json_array_from_lines
}

_run_backend_gate_json() {
    local sha="$1"

    if ! declare -F run_backend_launch_gate >/dev/null 2>&1; then
        export __BACKEND_LAUNCH_GATE_SOURCED=1
        source "$REPO_ROOT/scripts/launch/backend_launch_gate.sh"
    fi

    run_backend_launch_gate --sha="$sha"
}

_assemble_evidence_json() {
    local sha="$1"
    local branch="$2"
    local timestamp="$3"
    local rust_json="$4"
    local shell_json="$5"
    local gate_json="$6"

    SHA="$sha" \
    BRANCH="$branch" \
    TS="$timestamp" \
    RUST_JSON="$rust_json" \
    SHELL_JSON="$shell_json" \
    GATE_JSON="$gate_json" \
    python3 -c 'import json, os

external_blockers = []
_seen_blockers = set()

GATE_REASON_BLOCKER_MAP = {
    "security_dep_audit": {
        "blocker": "security_dep_audit",
        "owner": "Stuart",
        "command": "cargo audit -q",
    },
    "aws_creds_invalid": {
        "blocker": "aws_creds_invalid",
        "owner": "Stuart",
        "command": "aws sts get-caller-identity",
    },
    "github_auth_invalid": {
        "blocker": "github_auth_invalid",
        "owner": "Stuart",
        "command": "gh auth status",
    },
}

def _add_blocker(blocker, owner, command):
    key = (str(blocker), str(owner), str(command))
    if key in _seen_blockers:
        return
    _seen_blockers.add(key)
    external_blockers.append({
        "blocker": str(blocker),
        "owner": str(owner),
        "command": str(command),
    })

def _as_typed_json(raw, label, expected_type, rerun_command):
    try:
        value = json.loads(raw)
    except Exception:
        _add_blocker(f"{label}_invalid_json", "automation", rerun_command)
        return expected_type()

    if isinstance(value, expected_type):
        return value

    _add_blocker(f"{label}_invalid_json", "automation", rerun_command)
    return expected_type()

def _as_list(raw, label, rerun_command):
    return _as_typed_json(raw, label, list, rerun_command)

def _as_dict(raw, label, rerun_command):
    return _as_typed_json(raw, label, dict, rerun_command)

def _coerce_count(value, label, rerun_command):
    try:
        return int(value)
    except Exception:
        _add_blocker(f"{label}_invalid_counts", "automation", rerun_command)
        return 0

def _normalize_test_rows(rows, label, rerun_command):
    normalized = []
    has_failures = False
    for item in rows:
        if not isinstance(item, dict):
            continue
        normalized_item = dict(item)
        normalized_item["passed"] = _coerce_count(item.get("passed", 0), label, rerun_command)
        normalized_item["failed"] = _coerce_count(item.get("failed", 0), label, rerun_command)
        if normalized_item["failed"] > 0:
            has_failures = True
        normalized.append(normalized_item)
    return normalized, has_failures

rust_workspace, rust_has_failures = _normalize_test_rows(
    _as_list(os.environ.get("RUST_JSON", "[]"), "rust_workspace", "rerun collect_evidence.sh"),
    "rust_workspace",
    "rerun collect_evidence.sh",
)
shell_tests, shell_has_failures = _normalize_test_rows(
    _as_list(os.environ.get("SHELL_JSON", "[]"), "shell_tests", "rerun collect_evidence.sh"),
    "shell_tests",
    "rerun collect_evidence.sh",
)
gate_payload = _as_dict(os.environ.get("GATE_JSON", "{}"), "gates", "rerun backend launch gate")

gates = gate_payload.get("gates") if isinstance(gate_payload, dict) else []
if not isinstance(gates, list):
    gates = []

for gate in gates:
    if not isinstance(gate, dict):
        continue

    if gate.get("status") != "fail":
        continue

    reason = str(gate.get("reason", "")).strip()
    gate_name = str(gate.get("name", "unknown")).strip() or "unknown"
    mapped = GATE_REASON_BLOCKER_MAP.get(reason)
    if mapped:
        _add_blocker(mapped["blocker"], mapped["owner"], mapped["command"])
    elif reason:
        _add_blocker(reason, "automation", f"resolve {gate_name} gate failure")
    else:
        _add_blocker(f"{gate_name}_gate_failed", "automation", "rerun backend launch gate")

gate_verdict = "fail"
if isinstance(gate_payload, dict) and gate_payload.get("verdict") in ("pass", "fail"):
    gate_verdict = gate_payload.get("verdict")

overall_verdict = "pass"
if gate_verdict != "pass":
    overall_verdict = "fail"
if rust_has_failures:
    overall_verdict = "fail"
if shell_has_failures:
    overall_verdict = "fail"
if external_blockers:
    overall_verdict = "fail"

result = {
    "git": {
        "sha": os.environ.get("SHA", ""),
        "branch": os.environ.get("BRANCH", ""),
        "timestamp": os.environ.get("TS", ""),
    },
    "rust_workspace": rust_workspace,
    "shell_tests": shell_tests,
    "gates": gates,
    "overall_verdict": overall_verdict,
    "external_blockers": external_blockers,
}
print(json.dumps(result))'
}

_next_evidence_path() {
    local evidence_dir="$1"

    while true; do
        local candidate
        candidate="$evidence_dir/evidence_$(date +%Y-%m-%d_%H%M%S).json"
        if [ ! -e "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        sleep 1
    done
}

_append_index_line() {
    local evidence_dir="$1"
    local evidence_path="$2"
    local evidence_json="$3"

    local index_file="$evidence_dir/INDEX.md"

    local summary
    summary="$(EVIDENCE_JSON="$evidence_json" EVIDENCE_FILE="$(basename "$evidence_path")" python3 -c 'import json, os
payload = json.loads(os.environ["EVIDENCE_JSON"])
sha = payload.get("git", {}).get("sha", "")
ts = payload.get("git", {}).get("timestamp", "")
verdict = payload.get("overall_verdict", "fail")
rust = payload.get("rust_workspace", [])
shell = payload.get("shell_tests", [])
def _to_int(value):
    try:
        return int(value)
    except Exception:
        return 0
rust_passed = sum(_to_int(item.get("passed", 0)) for item in rust if isinstance(item, dict))
rust_failed = sum(_to_int(item.get("failed", 0)) for item in rust if isinstance(item, dict))
shell_passed = sum(_to_int(item.get("passed", 0)) for item in shell if isinstance(item, dict))
shell_failed = sum(_to_int(item.get("failed", 0)) for item in shell if isinstance(item, dict))
evidence_file = os.environ["EVIDENCE_FILE"]
print(f"{ts} sha={sha} verdict={verdict} rust={rust_passed}/{rust_failed} shell={shell_passed}/{shell_failed} file={evidence_file}")')"

    printf '%s\n' "$summary" >> "$index_file"
}

collect_evidence() {
    COLLECT_SHA=""
    COLLECT_EVIDENCE_DIR="${COLLECT_EVIDENCE_DIR:-$REPO_ROOT/docs/launch/evidence}"

    local arg
    for arg in "$@"; do
        case "$arg" in
            --sha=*)
                COLLECT_SHA="${arg#--sha=}"
                ;;
            --evidence-dir=*)
                COLLECT_EVIDENCE_DIR="${arg#--evidence-dir=}"
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

    if [ -z "$COLLECT_SHA" ]; then
        echo "ERROR: --sha is required" >&2
        print_usage
        return 2
    fi

    if [[ ! "$COLLECT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        echo "ERROR: --sha must be a 40-character lowercase hexadecimal commit SHA" >&2
        return 2
    fi

    local branch
    if ! branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
        branch="unknown"
    fi

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local rust_json shell_json gate_json
    rust_json="$(_run_cargo_tests)"
    shell_json="$(_run_shell_suites)"

    local gate_exit=0
    if gate_json="$(_run_backend_gate_json "$COLLECT_SHA")"; then
        gate_exit=0
    else
        gate_exit=$?
    fi

    local evidence_json
    evidence_json="$(_assemble_evidence_json "$COLLECT_SHA" "$branch" "$timestamp" "$rust_json" "$shell_json" "$gate_json")"

    mkdir -p "$COLLECT_EVIDENCE_DIR"
    local evidence_path
    evidence_path="$(_next_evidence_path "$COLLECT_EVIDENCE_DIR")"

    printf '%s\n' "$evidence_json" > "$evidence_path"
    _append_index_line "$COLLECT_EVIDENCE_DIR" "$evidence_path" "$evidence_json"

    printf '%s\n' "$evidence_json"

    if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); raise SystemExit(0 if d.get("overall_verdict") == "pass" else 1)' <<< "$evidence_json"; then
        return 0
    fi

    if [ "$gate_exit" -ne 0 ]; then
        return "$gate_exit"
    fi
    return 1
}

if [[ "${__COLLECT_EVIDENCE_SOURCED:-0}" != "1" ]]; then
    collect_evidence "$@"
fi
