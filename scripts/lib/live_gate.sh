#!/usr/bin/env bash
# Live gate enforcement for bash scripts.
#
# When BACKEND_LIVE_GATE=1, precondition failures are fatal (exit 1).
# When BACKEND_LIVE_GATE is unset or not "1", failures print a skip message
# and return 0, preserving existing skip-and-continue behavior.
#
# Usage:
#   source scripts/lib/live_gate.sh
#   live_gate_require "$some_condition" "reason for requirement"

set -euo pipefail

# Returns 0 (true) when the backend live gate is active.
live_gate_enabled() {
    [ "${BACKEND_LIVE_GATE:-}" = "1" ]
}

# Check a precondition with live gate enforcement.
#
# Arguments:
#   $1..$N-1 — condition command and args (executed directly, no eval)
#   $N — human-readable reason describing the precondition
#
# Behavior:
#   - Condition true → returns 0, no output.
#   - Condition false + gate on → prints failure message to stderr, exits 1.
#   - Condition false + gate off → prints "[skip] reason" to stderr, returns 0.
live_gate_require() {
    if [ "$#" -lt 2 ]; then
        echo "[live_gate_require] usage: live_gate_require <condition...> <reason>" >&2
        return 2
    fi

    local reason="${!#}"
    local condition_count=$(( $# - 1 ))
    local condition_cmd=( "${@:1:$condition_count}" )

    if "${condition_cmd[@]}"; then
        return 0
    fi

    if live_gate_enabled; then
        echo "[BACKEND_LIVE_GATE] required precondition failed: $reason" >&2
        exit 1
    else
        echo "[skip] $reason" >&2
        return 0
    fi
}

# Emit a structured REASON code and fail/skip via live gate semantics.
#
# Arguments:
#   $1 — machine-readable reason code (without "REASON: " prefix)
#   $2 — human-readable reason describing the precondition failure
#
# Behavior:
#   - Always emits `REASON: <code>` to stderr.
#   - Gate on  → exits 1 via live_gate_require false.
#   - Gate off → prints [skip] message and returns 0.
live_gate_fail_with_reason() {
    local reason_code="$1"
    local reason="$2"

    echo "REASON: $reason_code" >&2
    live_gate_require false "$reason"
    return 0
}

# Portable millisecond timestamp (macOS date lacks %N).
# Shared by live-backend-gate.sh, security_checks.sh, and any future gate libs.
_ms_now() {
    python3 -c 'import time; print(int(time.time()*1000))'
}

# Normalize a structured REASON line from check output.
# Accepts both "REASON: CODE" and "REASON:CODE" formats.
_strip_reason_prefix() {
    local reason_line="$1"
    local reason="${reason_line#REASON: }"
    reason="${reason#REASON:}"
    echo "$reason"
}

# Portable timeout helper (macOS/Linux) with GNU-timeout-compatible return code.
#
# Usage:
#   _gate_timeout <seconds> <command> [args...]
#
# Behavior:
#   - Command completes before timeout: returns command exit code, passes stdout/stderr through.
#   - Command exceeds timeout: sends SIGTERM and returns 124.
_gate_timeout() {
    local timeout_sec="$1"
    shift

    if [ "$#" -eq 0 ]; then
        return 125
    fi

    local alive_file sleep_pid_file
    alive_file="$(mktemp)"
    sleep_pid_file="$(mktemp)"
    local exit_code=0

    "$@" &
    local cmd_pid=$!

    (
        sleep "$timeout_sec" &
        local _sleep_pid=$!
        printf '%s\n' "$_sleep_pid" > "$sleep_pid_file"
        wait "$_sleep_pid" 2>/dev/null
        if [ -f "$alive_file" ]; then
            kill "$cmd_pid" 2>/dev/null || true
        fi
    ) >/dev/null 2>&1 &
    local watchdog_pid=$!

    wait "$cmd_pid" 2>/dev/null || exit_code=$?

    rm -f "$alive_file"

    local _sleep_pid="" _attempt
    for _attempt in 1 2 3 4 5 6 7 8 9 10; do
        _sleep_pid="$(cat "$sleep_pid_file" 2>/dev/null || echo "")"
        [ -n "$_sleep_pid" ] && break
        sleep 0.01 2>/dev/null || true
    done
    [ -n "$_sleep_pid" ] && kill "$_sleep_pid" 2>/dev/null || true
    rm -f "$sleep_pid_file"

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    # Normalize timeout SIGTERM to GNU timeout exit convention.
    if [ "$exit_code" -eq 143 ]; then
        return 124
    fi
    return "$exit_code"
}
