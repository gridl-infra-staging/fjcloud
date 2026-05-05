#!/usr/bin/env bash
# Backend launch gate — orchestrates all required backend validation checks
# and produces a machine-readable JSON summary.
#
# Usage:
#   scripts/live-backend-gate.sh [--skip-rust-tests] [--fail-fast] [--staging-only]
#
# Options:
#   --skip-rust-tests  Skip Rust validation tests (cargo test)
#   --fail-fast        Stop on first check failure
#   --staging-only     Force commerce checks into soft-skip mode (BACKEND_LIVE_GATE=0)
#
# Output:
#   stdout: JSON summary with check_results, reason codes, and timing
#   stderr: Per-check progress (always printed)
#
# Exit codes:
#   0 — all checks passed (or were skipped in dev mode)
#   1 — one or more actionable gate failures
#
# Environment:
#   GATE_CHECK_TIMEOUT_SEC  Per-check timeout in seconds (default: 30)

set -euo pipefail

_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_GATE_DIR/.." && pwd)"

# Source gate enforcement and check libraries
source "$_GATE_DIR/lib/live_gate.sh"
source "$_GATE_DIR/lib/stripe_checks.sh"
source "$_GATE_DIR/lib/metering_checks.sh"

# Gate defaults to launch mode, but supports explicit dev-mode override.
export BACKEND_LIVE_GATE="${BACKEND_LIVE_GATE:-1}"

# Per-check timeout (seconds). Override with GATE_CHECK_TIMEOUT_SEC env var.
: "${GATE_CHECK_TIMEOUT_SEC:=30}"
export GATE_CHECK_TIMEOUT_SEC

# Inner dependency timeout (seconds). Check libraries use this to emit
# dependency-specific timeout REASON codes before outer watchdog expiry.
: "${GATE_INNER_TIMEOUT_SEC:=10}"
export GATE_INNER_TIMEOUT_SEC

# ---------------------------------------------------------------------------
# State arrays (parallel indexed)
# ---------------------------------------------------------------------------
_CHECK_NAMES=()
_CHECK_RESULTS=()   # "pass", "fail", or "skipped"
_CHECK_ELAPSED=()   # milliseconds per check
_CHECK_REASONS=()   # reason string (empty for pass, descriptive for fail/skip)
_CHECK_ERROR_CLASS=()  # error classification: "", "timeout", "precondition", "runtime"

# ---------------------------------------------------------------------------
# _classify_error — determine error class from exit code and captured output
#
# Arguments:
#   $1 — exit code
#   $2 — captured stderr/stdout text
#
# Prints: error class string
# ---------------------------------------------------------------------------
_classify_error() {
    local exit_code="$1"
    local output="$2"

    # Exit code 124 = timeout(1) killed the process
    # Exit code 137 = SIGKILL (timeout -s KILL or OOM)
    # Exit code 143 = SIGTERM (watchdog killed the process)
    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ] || [ "$exit_code" -eq 143 ]; then
        echo "timeout"
        return
    fi

    # live_gate_require precondition failure marker
    if [[ "$output" == *"[BACKEND_LIVE_GATE]"* ]]; then
        echo "precondition"
        return
    fi

    echo "runtime"
}

# ---------------------------------------------------------------------------
# _extract_reason — extract a human-readable reason from captured output
#
# Arguments:
#   $1 — exit code
#   $2 — captured stderr/stdout text
#
# Prints: reason string
# ---------------------------------------------------------------------------
_extract_reason() {
    local exit_code="$1"
    local output="$2"

    # Look for REASON: prefix (structured reason code from check libs)
    local reason_line
    reason_line="$(echo "$output" | grep -m1 '^REASON:' || true)"
    if [ -n "$reason_line" ]; then
        echo "$(_strip_reason_prefix "$reason_line")"
        return
    fi

    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ] || [ "$exit_code" -eq 143 ]; then
        echo "timeout_exceeded (>${GATE_CHECK_TIMEOUT_SEC}s)"
        return
    fi

    # Look for live_gate_require failure message
    local gate_line
    gate_line="$(echo "$output" | grep -m1 '\[BACKEND_LIVE_GATE\]' || true)"
    if [ -n "$gate_line" ]; then
        # Strip the prefix to get just the reason
        echo "${gate_line#*required precondition failed: }"
        return
    fi

    # Fall back to first non-empty line of output
    local first_line
    first_line="$(echo "$output" | grep -m1 '.' || true)"
    if [ -n "$first_line" ]; then
        echo "$first_line"
        return
    fi

    echo "unknown_error"
}

# ---------------------------------------------------------------------------
# _detect_skip_pass — check if a passing check actually skipped its validation
#
# Arguments:
#   $1 — captured stderr/stdout text
#
# Returns: 0 if skip detected, 1 otherwise
# ---------------------------------------------------------------------------
_detect_skip_pass() {
    local output="$1"
    [[ "$output" == *"[skip]"* ]]
}

# ---------------------------------------------------------------------------
# _extract_skip_reason — extract skip reason from [skip] output
# ---------------------------------------------------------------------------
_extract_skip_reason() {
    local output="$1"
    local skip_line
    skip_line="$(echo "$output" | grep -m1 '\[skip\]' || true)"
    if [ -n "$skip_line" ]; then
        echo "${skip_line#*\[skip\] }"
    else
        echo "validation_skipped"
    fi
}

# ---------------------------------------------------------------------------
# _kill_process_tree — best-effort recursive termination of a PID and children.
#
# Uses pgrep -P for portability on macOS and Linux. This is invoked only when
# a check has timed out, so we prioritize cleanup over strict ordering.
# ---------------------------------------------------------------------------
_kill_process_tree() {
    local root_pid="$1"
    [ -n "$root_pid" ] || return 0

    local child_pids child
    child_pids="$(pgrep -P "$root_pid" 2>/dev/null || true)"
    for child in $child_pids; do
        _kill_process_tree "$child"
    done

    kill "$root_pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _pid_is_live_child — verify PID still belongs to the expected direct parent.
#
# This protects timeout cleanup from PID reuse: if the original check process
# has already exited and the PID was recycled, parent mismatch prevents us from
# signaling an unrelated process.
# ---------------------------------------------------------------------------
_pid_is_live_child() {
    local pid="$1"
    local expected_ppid="$2"
    [ -n "$pid" ] || return 1
    [ -n "$expected_ppid" ] || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$expected_ppid" =~ ^[0-9]+$ ]] || return 1

    local actual_ppid
    actual_ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || return 1
    [ -n "$actual_ppid" ] || return 1
    [ "$actual_ppid" = "$expected_ppid" ]
}

# ---------------------------------------------------------------------------
# run_check — execute a check function in a subshell with timeout, capture
#             result, reason, and error classification.
#
# Arguments:
#   $1 — check name (used in JSON output and progress)
#   $2 — check command symbol (function name or executable)
#   $3... — optional command arguments
#
# Globals modified:
#   _CHECK_NAMES, _CHECK_RESULTS, _CHECK_ELAPSED, _CHECK_REASONS,
#   _CHECK_ERROR_CLASS
# ---------------------------------------------------------------------------
run_check() {
    local name="$1"
    shift
    local cmd="$1"
    shift || true
    local tmpfile alive_file sleep_pid_file
    tmpfile="$(mktemp)"
    alive_file="$(mktemp)"
    sleep_pid_file="$(mktemp)"
    local launcher_pid="${BASHPID:-$$}"

    local start_ms exit_code=0
    start_ms="$(_ms_now)"

    # Run in subshell with timeout via background+wait pattern.
    # Subshell inherits all function definitions (needed for check functions).
    ( "$cmd" "$@" ) >"$tmpfile" 2>&1 &
    local check_pid=$!

    # Watchdog: records its sleep child PID for explicit cancellation and
    # guards kill with an alive_file sentinel to prevent hitting a recycled PID
    # if the check completes before the timeout fires.
    (
        sleep "$GATE_CHECK_TIMEOUT_SEC" &
        local _sleep_pid=$!
        printf '%s\n' "$_sleep_pid" > "$sleep_pid_file"
        wait "$_sleep_pid" 2>/dev/null
        if [ -f "$alive_file" ] && _pid_is_live_child "$check_pid" "$launcher_pid"; then
            # Timeout hit: terminate check process tree, not just the shell.
            _kill_process_tree "$check_pid"
        fi
    ) &
    local watchdog_pid=$!

    wait "$check_pid" 2>/dev/null || exit_code=$?

    # Remove sentinel FIRST — prevents watchdog from issuing a stale kill even
    # if it wakes between wait() return and the cleanup below.
    rm -f "$alive_file"

    # Cancel the watchdog's sleep child to avoid leaving orphan processes.
    # Brief retry handles the startup race where sleep_pid_file may not be
    # written yet if the check completed before the watchdog subshell ran.
    local _sleep_pid="" _attempt
    for _attempt in 1 2 3 4 5 6 7 8 9 10; do
        _sleep_pid="$(cat "$sleep_pid_file" 2>/dev/null || echo "")"
        [ -n "$_sleep_pid" ] && break
        sleep 0.01 2>/dev/null || true
    done
    [ -n "$_sleep_pid" ] && kill "$_sleep_pid" 2>/dev/null || true
    rm -f "$sleep_pid_file"

    # Kill and reap the watchdog subshell.
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    local end_ms
    end_ms="$(_ms_now)"

    local elapsed_ms=$(( end_ms - start_ms ))

    _CHECK_NAMES+=("$name")
    _CHECK_ELAPSED+=("$elapsed_ms")

    local captured
    captured="$(cat "$tmpfile")"
    rm -f "$tmpfile"

    if [ "$exit_code" -eq 0 ]; then
        # Check for skip-pass: exit 0 but [skip] marker in output
        if _detect_skip_pass "$captured"; then
            _CHECK_RESULTS+=("skipped")
            _CHECK_REASONS+=("$(_extract_skip_reason "$captured")")
            _CHECK_ERROR_CLASS+=("skipped")
            echo "  [SKIP] $name (${elapsed_ms}ms)" >&2
        else
            _CHECK_RESULTS+=("pass")
            _CHECK_REASONS+=("")
            _CHECK_ERROR_CLASS+=("")
            echo "  [PASS] $name (${elapsed_ms}ms)" >&2
        fi
    else
        local error_class reason
        error_class="$(_classify_error "$exit_code" "$captured")"
        reason="$(_extract_reason "$exit_code" "$captured")"

        _CHECK_RESULTS+=("fail")
        _CHECK_REASONS+=("$reason")
        _CHECK_ERROR_CLASS+=("$error_class")
        echo "  [FAIL] $name (${elapsed_ms}ms) [$error_class]" >&2
        if [ -n "$captured" ]; then
            echo "         $captured" >&2
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# record_skip — record a check as explicitly skipped (never executed)
#
# Arguments:
#   $1 — check name
#   $2 — reason for skip
# ---------------------------------------------------------------------------
record_skip() {
    local name="$1"
    local reason="$2"

    _CHECK_NAMES+=("$name")
    _CHECK_RESULTS+=("skipped")
    _CHECK_ELAPSED+=(0)
    _CHECK_REASONS+=("$reason")
    _CHECK_ERROR_CLASS+=("skipped")

    echo "  [SKIP] $name (0ms) — $reason" >&2
}

# ---------------------------------------------------------------------------
# build_json — produce the JSON summary from state arrays using python3
#              for reliable JSON construction with deterministic field ordering.
#              Uses a temp TSV file to avoid delimiter collisions.
# ---------------------------------------------------------------------------
build_json() {
    local total_elapsed_ms="$1"
    local gate_failed="$2"
    local data_file
    data_file="$(mktemp)"

    for i in "${!_CHECK_NAMES[@]}"; do
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${_CHECK_NAMES[$i]}" \
            "${_CHECK_RESULTS[$i]}" \
            "${_CHECK_ELAPSED[$i]}" \
            "${_CHECK_REASONS[$i]}" \
            "${_CHECK_ERROR_CLASS[$i]}" >> "$data_file"
    done

python3 - "$data_file" "$total_elapsed_ms" "$gate_failed" <<'PYEOF'
import json
import os
import sys

data_file = sys.argv[1]
total_elapsed = int(sys.argv[2])
gate_failed = sys.argv[3] == "1"
launch_mode = os.environ.get("BACKEND_LIVE_GATE", "0") == "1"

check_results = []
failures = []
checks_run = 0
checks_failed = 0
checks_skipped = 0
has_non_exempt_skip = False

def is_non_failing_skip(name: str, reason: str) -> bool:
    return name == "rust_validation_tests" and reason == "skip_rust_tests_flag"

with open(data_file) as f:
    for line in f:
        line = line.rstrip('\n')
        if not line:
            continue
        parts = line.split('\t', 4)
        name = parts[0]
        status = parts[1] if len(parts) > 1 else 'unknown'
        elapsed = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
        reason = parts[3] if len(parts) > 3 else ''
        error_class = parts[4] if len(parts) > 4 else ''

        entry = {
            'error_class': error_class,
            'elapsed_ms': elapsed,
            'name': name,
            'reason': reason,
            'status': status,
        }

        check_results.append(entry)

        if status == 'fail':
            checks_failed += 1
            checks_run += 1
            failures.append(name)
        elif status == 'pass':
            checks_run += 1
        elif status == 'skipped':
            checks_skipped += 1
            if launch_mode and not is_non_failing_skip(name, reason):
                has_non_exempt_skip = True

passed = not (checks_failed > 0 or has_non_exempt_skip)
if gate_failed:
    passed = False

output = {
    'check_results': check_results,
    'checks_failed': checks_failed,
    'checks_run': checks_run,
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
# _is_non_failing_skip — classify skips that should not fail the gate
#
# Arguments:
#   $1 — check name
#   $2 — skip reason
#
# Returns: 0 for skips that are explicitly allowed, 1 otherwise
# ---------------------------------------------------------------------------
_is_non_failing_skip() {
    local name="$1"
    local reason="$2"
    [ "$name" = "rust_validation_tests" ] && [ "$reason" = "skip_rust_tests_flag" ]
}

# Run live Rust validation from infra workspace and force both INTEGRATION=1
# and BACKEND_LIVE_GATE=1 so integration tests execute real precondition checks.
run_live_rust_validation_tests() {
    (
        cd "$_REPO_ROOT/infra" &&
        INTEGRATION=1 BACKEND_LIVE_GATE=1 \
            cargo test -p api --test integration_metering_pipeline_test -- --test-threads=1
    )
}

# ---------------------------------------------------------------------------
# _has_gate_failure — scan check results for actionable failures
#
# Returns: 0 (true) if any check failed or was non-exempt skipped, 1 otherwise
# ---------------------------------------------------------------------------
_has_gate_failure() {
    local launch_mode=0
    if [ "${BACKEND_LIVE_GATE:-0}" = "1" ]; then
        launch_mode=1
    fi

    for i in "${!_CHECK_RESULTS[@]}"; do
        local result="${_CHECK_RESULTS[$i]}"
        if [ "$result" = "fail" ]; then
            return 0
        fi
        if [ "$result" = "skipped" ] && [ "$launch_mode" -eq 1 ] && \
           ! _is_non_failing_skip "${_CHECK_NAMES[$i]}" "${_CHECK_REASONS[$i]}"; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# run_gate — main orchestration function
#
# Arguments: [--skip-rust-tests] [--fail-fast]
# ---------------------------------------------------------------------------
run_gate() {
    local skip_rust=false
    local fail_fast=false
    local staging_only=false
    local original_backend_live_gate="${BACKEND_LIVE_GATE:-1}"

    # Parse flags
    for arg in "$@"; do
        case "$arg" in
            --skip-rust-tests) skip_rust=true ;;
            --fail-fast) fail_fast=true ;;
            --staging-only) staging_only=true ;;
            *) echo "Unknown flag: $arg" >&2; return 1 ;;
        esac
    done

    if $staging_only; then
        export BACKEND_LIVE_GATE=0
    fi

    # Reset state
    _CHECK_NAMES=()
    _CHECK_RESULTS=()
    _CHECK_ELAPSED=()
    _CHECK_REASONS=()
    _CHECK_ERROR_CLASS=()

    local gate_start_ms
    gate_start_ms="$(_ms_now)"

    echo "Backend launch gate — running checks..." >&2

    # All checks (bash + rust) in canonical order
    local bash_checks=(
        "check_stripe_key_present"
        "check_stripe_key_live"
        "check_stripe_webhook_secret_present"
        "check_stripe_webhook_forwarding"
        "check_usage_records_populated"
        "check_rollup_current"
    )

    local hit_failure=false

    for check_fn in "${bash_checks[@]}"; do
        if $hit_failure && $fail_fast; then
            record_skip "$check_fn" "fail_fast"
        else
            run_check "$check_fn" "$check_fn"

            local _last_idx=$(( ${#_CHECK_RESULTS[@]} - 1 ))
            if [ "${_CHECK_RESULTS[$_last_idx]}" = "fail" ]; then
                hit_failure=true
                if $fail_fast; then
                    echo "  --fail-fast: stopping after first failure" >&2
                fi
            fi
        fi
    done

    # Rust validation tests
    if $skip_rust; then
        record_skip "rust_validation_tests" "skip_rust_tests_flag"
    elif $hit_failure && $fail_fast; then
        record_skip "rust_validation_tests" "fail_fast"
    else
        run_check "rust_validation_tests" "run_live_rust_validation_tests"
    fi

    local gate_end_ms
    gate_end_ms="$(_ms_now)"
    local total_elapsed=$(( gate_end_ms - gate_start_ms ))

    echo "" >&2

    local gate_failed=0
    if _has_gate_failure; then
        gate_failed=1
    fi

    # Build and emit JSON
    local json
    json="$(build_json "$total_elapsed" "$gate_failed")"
    echo "$json"

    # Determine exit code
    if $staging_only; then
        export BACKEND_LIVE_GATE="$original_backend_live_gate"
    fi
    if [ "$gate_failed" -eq 1 ]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Entry point — only run main when NOT sourced by tests
# ---------------------------------------------------------------------------
if [ -z "${__LIVE_BACKEND_GATE_SOURCED:-}" ]; then
    run_gate "$@"
fi
