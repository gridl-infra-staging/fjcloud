#!/usr/bin/env bash
# Shared process management helpers for shell scripts.
#
# Callers must define:
#   log "<message>"

# Kills the process recorded in a PID file, with stale-PID safety.
# Args: pid_file name expected_cmd
# Skips the kill if the PID's actual command doesn't match expected_cmd.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
# TODO: Document kill_pid_file.
kill_pid_file() {
    local pid_file="$1" name="$2" expected_cmd="$3"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            local actual_cmd actual_base
            actual_cmd="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            actual_base="${actual_cmd##*/}"
            if [ -n "$actual_base" ] && [[ "$actual_base" != *"$expected_cmd"* ]]; then
                log "PID $pid belongs to '$actual_base', not '$name' — skipping kill (stale PID file)"
            else
                log "Stopping $name (PID $pid)..."
                kill "$pid" 2>/dev/null || true
                # Wait up to 5 seconds for graceful shutdown
                local elapsed=0
                while [ $elapsed -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
                    sleep 1
                    elapsed=$((elapsed + 1))
                done
                # Force kill if still alive
                if kill -0 "$pid" 2>/dev/null; then
                    log "Force-killing $name (PID $pid)..."
                    kill -9 "$pid" 2>/dev/null || true
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
