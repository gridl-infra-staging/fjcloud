#!/usr/bin/env bash
# Security automation gate — orchestrates all security checks and produces
# a machine-readable JSON summary.
#
# Usage:
#   scripts/reliability/security_checks.sh [--check <name>]
#
# Options:
#   --check cargo_audit       Run only cargo audit check
#   --check secret_scan       Run only secret scan check
#   --check unsafe_code       Run only unsafe code patterns check
#   (no flags)                Run all three checks
#
# Output:
#   stdout: JSON summary with per-check pass/fail, reason codes, and timing
#   stderr: Per-check progress
#
# Exit codes:
#   0 — all checks passed (cargo_audit skip is still treated as non-pass)
#   1 — one or more checks failed or skipped

set -euo pipefail

_SEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_SEC_DIR/../.." && pwd)"

# Source check libraries
source "$_REPO_ROOT/scripts/lib/live_gate.sh"
source "$_REPO_ROOT/scripts/lib/security_checks.sh"

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
live_gate_require \
    command -v git \
    "git is required for secret scanning"

live_gate_require \
    test -f "$_REPO_ROOT/infra/Cargo.lock" \
    "infra/Cargo.lock must exist for cargo audit"

# ---------------------------------------------------------------------------
# Portable millisecond timestamp
# ---------------------------------------------------------------------------
_ms_now() {
    python3 -c 'import time; print(int(time.time()*1000))'
}

# ---------------------------------------------------------------------------
# State arrays (parallel indexed)
# ---------------------------------------------------------------------------
_CHECK_NAMES=()
_CHECK_RESULTS=()   # "pass", "fail", or "skip"
_CHECK_ELAPSED=()   # milliseconds per check
_CHECK_REASONS=()   # reason string (empty for pass)

# ---------------------------------------------------------------------------
# _run_security_check — execute a check function, capture result and timing
#
# Arguments:
#   $1 — check name (used in JSON output)
#   $2 — check function name
#   $@ — additional args passed to check function
# ---------------------------------------------------------------------------
_run_security_check() {
    local name="$1"
    shift
    local cmd="$1"
    shift

    local start_ms
    start_ms="$(_ms_now)"

    local output exit_code=0
    output="$($cmd "$@" 2>/dev/null)" || exit_code=$?

    local end_ms
    end_ms="$(_ms_now)"
    local elapsed_ms=$(( end_ms - start_ms ))

    _CHECK_NAMES+=("$name")
    _CHECK_ELAPSED+=("$elapsed_ms")

    if [ "$exit_code" -eq 0 ]; then
        _CHECK_RESULTS+=("pass")
        _CHECK_REASONS+=("")
        echo "  [PASS] $name (${elapsed_ms}ms)" >&2
    else
        # Extract status and reason from JSON output
        local status reason
        status="$(echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status","fail"))' 2>/dev/null || echo "fail")"
        reason="$(echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("reason","unknown"))' 2>/dev/null || echo "unknown")"
        _CHECK_RESULTS+=("$status")
        _CHECK_REASONS+=("$reason")
        local status_upper
        status_upper="$(echo "$status" | tr '[:lower:]' '[:upper:]')"
        echo "  [$status_upper] $name (${elapsed_ms}ms) — $reason" >&2
    fi

    # Always echo the per-check JSON line to stdout
    echo "$output"
    return 0
}

# ---------------------------------------------------------------------------
# _build_summary_json — produce the JSON summary from state arrays
# ---------------------------------------------------------------------------
_build_summary_json() {
    local total_elapsed_ms="$1"
    local data_file
    data_file="$(mktemp)"

    for i in "${!_CHECK_NAMES[@]}"; do
        printf '%s\t%s\t%s\t%s\n' \
            "${_CHECK_NAMES[$i]}" \
            "${_CHECK_RESULTS[$i]}" \
            "${_CHECK_ELAPSED[$i]}" \
            "${_CHECK_REASONS[$i]}" >> "$data_file"
    done

    python3 - "$data_file" "$total_elapsed_ms" <<'PYEOF'
import json, sys

data_file = sys.argv[1]
total_elapsed = int(sys.argv[2])

check_results = []
checks_passed = 0
checks_failed = 0
checks_skipped = 0
failures = []

with open(data_file) as f:
    for line in f:
        line = line.rstrip('\n')
        if not line:
            continue
        parts = line.split('\t', 3)
        name = parts[0]
        status = parts[1] if len(parts) > 1 else 'unknown'
        elapsed = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
        reason = parts[3] if len(parts) > 3 else ''

        check_results.append({
            'name': name,
            'status': status,
            'elapsed_ms': elapsed,
            'reason': reason,
        })

        if status == 'pass':
            checks_passed += 1
        elif status == 'fail':
            checks_failed += 1
            failures.append(name)
        elif status == 'skip':
            checks_skipped += 1

passed = checks_failed == 0 and checks_skipped == 0

output = {
    'check_results': check_results,
    'checks_failed': checks_failed,
    'checks_passed': checks_passed,
    'checks_skipped': checks_skipped,
    'elapsed_ms': total_elapsed,
    'failures': failures,
    'passed': passed,
}

print(json.dumps(output, sort_keys=True))
PYEOF

    rm -f "$data_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local single_check=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --check)
                single_check="$2"
                shift 2
                ;;
            *)
                echo "Unknown flag: $1" >&2
                return 1
                ;;
        esac
    done

    local gate_start_ms
    gate_start_ms="$(_ms_now)"

    echo "Security checks — running..." >&2

    case "$single_check" in
        cargo_audit)
            _run_security_check "cargo_audit" check_cargo_audit
            ;;
        secret_scan)
            _run_security_check "secret_scan" check_secret_scan
            ;;
        unsafe_code)
            _run_security_check "unsafe_code_patterns" check_unsafe_code_patterns
            ;;
        "")
            # Run all checks
            _run_security_check "cargo_audit" check_cargo_audit
            _run_security_check "secret_scan" check_secret_scan
            _run_security_check "unsafe_code_patterns" check_unsafe_code_patterns
            ;;
        *)
            echo "Unknown check: $single_check (valid: cargo_audit, secret_scan, unsafe_code)" >&2
            return 1
            ;;
    esac

    local gate_end_ms
    gate_end_ms="$(_ms_now)"
    local total_elapsed=$(( gate_end_ms - gate_start_ms ))

    echo "" >&2

    # Build and emit summary JSON
    local summary
    summary="$(_build_summary_json "$total_elapsed")"
    echo "$summary"

    # Determine exit code
    local has_failure=false
    for result in "${_CHECK_RESULTS[@]}"; do
        if [ "$result" = "fail" ] || [ "$result" = "skip" ]; then
            has_failure=true
            break
        fi
    done

    if $has_failure; then
        return 1
    fi
    return 0
}

# Only run main when not sourced
if [ -z "${__SECURITY_CHECKS_SOURCED:-}" ]; then
    main "$@"
fi
