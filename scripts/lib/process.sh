#!/usr/bin/env bash
# Shared process management helpers for shell scripts.
#
# Callers must define:
#   log "<message>"

# Kills the process recorded in a PID file, with stale-PID safety.
# Args: pid_file name expected_cmd [expected_args_glob]
# Skips the kill unless the PID matches a strong process identity:
# either an explicit expected_args_glob provided by the caller, an exact
# command-line prefix match for path-like expected_cmd values, or an exact
# live command basename match for tracked exec'd binaries like `fjcloud-api`
# and `flapjack`.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# Remove a tracked process only after its live command identity matches the caller's contract.
# Always remove stale PID files without signaling unrelated or ambiguously identified processes.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
kill_pid_file() {
    local pid_file="$1" name="$2" expected_cmd="$3"
    local expected_args_glob="${4:-}"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ ! "$pid" =~ ^[0-9]+$ ]] || [ "$pid" -le 1 ]; then
            log "$name PID file contained invalid PID '$pid' — skipping kill"
        elif kill -0 -- "$pid" 2>/dev/null; then
            local actual_cmd actual_base actual_args matches_expected=0
            actual_cmd="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            actual_base="${actual_cmd##*/}"
            actual_args="$(ps -p "$pid" -o args= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [ -n "$expected_args_glob" ] && [[ "$actual_args" == $expected_args_glob ]]; then
                matches_expected=1
            elif [[ "$expected_cmd" == */* ]] && { [ "$actual_args" = "$expected_cmd" ] || [[ "$actual_args" == "$expected_cmd "* ]]; }; then
                matches_expected=1
            elif [[ "$expected_cmd" != */* ]] && [ "$actual_base" = "$expected_cmd" ]; then
                matches_expected=1
            fi

            if [ "$matches_expected" -ne 1 ]; then
                log "PID $pid command '$actual_base' did not match the expected $name identity — skipping kill (stale PID file or reused PID)"
            else
                log "Stopping $name (PID $pid)..."
                kill -- "$pid" 2>/dev/null || true
                # Wait up to 5 seconds for graceful shutdown
                local elapsed=0
                while [ $elapsed -lt 5 ] && kill -0 -- "$pid" 2>/dev/null; do
                    sleep 1
                    elapsed=$((elapsed + 1))
                done
                # Force kill if still alive
                if kill -0 -- "$pid" 2>/dev/null; then
                    log "Force-killing $name (PID $pid)..."
                    kill -9 -- "$pid" 2>/dev/null || true
                fi
            fi
        else
            log "$name not running (stale PID file)"
        fi
        rm -f "$pid_file"
    else
        log "$name: no PID file found (not running)"
    fi
}
