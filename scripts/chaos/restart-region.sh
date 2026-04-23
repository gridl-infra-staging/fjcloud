#!/usr/bin/env bash
# restart-region.sh — Restart a killed Flapjack region.
#
# Requires the Flapjack binary to be available (FLAPJACK_DEV_DIR or in PATH).
# After restart, the health monitor should detect recovery.
#
# Usage:
#   scripts/chaos/restart-region.sh eu-west-1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=../lib/health.sh
source "$REPO_ROOT/scripts/lib/health.sh"
# shellcheck source=../lib/flapjack_binary.sh
source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"

log() { echo "[restart-region] $*"; }
die() { echo "[restart-region] ERROR: $*" >&2; exit 1; }

PID_DIR="$REPO_ROOT/.local"
REGION="${1:?Usage: restart-region.sh <region>}"

load_env_file "$REPO_ROOT/.env.local"
FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"

# Parse the port for this region from FLAPJACK_REGIONS.
FLAPJACK_REGIONS="${FLAPJACK_REGIONS:-us-east-1:7700 eu-west-1:7701 eu-central-1:7702}"
PORT=""
for region_port in $FLAPJACK_REGIONS; do
    r="${region_port%%:*}"
    p="${region_port##*:}"
    if [ "$r" = "$REGION" ]; then
        PORT="$p"
        break
    fi
done

[ -n "$PORT" ] || die "Region '${REGION}' not found in FLAPJACK_REGIONS"

# Find the flapjack binary.
FLAPJACK_DEV_DIR="$(resolve_default_flapjack_dev_dir)"
FLAPJACK_BIN="$(find_restart_ready_flapjack_binary || true)"
[ -n "$FLAPJACK_BIN" ] && [ -x "$FLAPJACK_BIN" ] \
    || die "Flapjack binary not found in configured candidates or PATH"

DATA_DIR="$PID_DIR/flapjack-data-${REGION}"
PID_FILE="$PID_DIR/flapjack-${REGION}.pid"
LOG_FILE="$PID_DIR/flapjack-${REGION}.log"

mkdir -p "$DATA_DIR"

# Keep the post-health restart verdict tied to the launched process, not just
# the port state, because the PID can disappear between consecutive checks.
started_pid_is_live() {
    local pid="$1"
    local pid_state

    pid_state="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$pid_state" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    case "$pid_state" in
        *Z*) return 1 ;;
    esac

    return 0
}

report_started_pid_exit() {
    local pid="$1"

    if [ -s "$LOG_FILE" ]; then
        log "Last flapjack-${REGION} log lines:"
        tail -n 20 "$LOG_FILE" >&2 || true
    fi
    die "flapjack-${REGION} exited after health check (PID ${pid})"
}

verify_started_pid_alive() {
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"

    if [ -z "$pid" ]; then
        die "flapjack-${REGION} PID file was not written after restart"
    fi

    # The health endpoint can be briefly satisfied by stale/local state in tests
    # and during fast restarts, so require the exact launched PID to still be
    # alive before reporting durable recovery to the HA proof.
    if ! started_pid_is_live "$pid"; then
        report_started_pid_exit "$pid"
    fi

    if command -v lsof >/dev/null 2>&1; then
        # Health can be satisfied by a stale listener if restart raced with an
        # old process. When lsof is available, tie the PID file to the actual
        # listening socket so "restarted" means this process owns the port.
        # Give the launched PID a brief settle window so short-lived wrapper
        # processes report as exited instead of looking like a stale listener.
        local listener_pids attempt
        for attempt in 1 2 3 4 5; do
            if ! started_pid_is_live "$pid"; then
                report_started_pid_exit "$pid"
            fi
            listener_pids="$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
            if printf '%s\n' "$listener_pids" | grep -qx "$pid"; then
                return 0
            fi
            if [ "$attempt" -lt 5 ]; then
                sleep 0.1
            fi
        done

        if ! started_pid_is_live "$pid"; then
            report_started_pid_exit "$pid"
        fi
        die "flapjack-${REGION} PID ${pid} is not listening on port ${PORT}"
    fi
}

log "Restarting flapjack-${REGION} on port ${PORT}..."

FLAPJACK_ADMIN_KEY="$FLAPJACK_ADMIN_KEY" \
    nohup "$FLAPJACK_BIN" \
        --port "$PORT" \
        --data-dir "$DATA_DIR" \
        < /dev/null > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

wait_for_health "http://127.0.0.1:${PORT}/health" "flapjack-${REGION}" 15 \
    || die "flapjack-${REGION} did not become healthy after restart"
verify_started_pid_alive

log "flapjack-${REGION} restarted (PID $(cat "$PID_FILE"))"
_recover_interval="${REGION_FAILOVER_CYCLE_INTERVAL_SECS:-60}"
_recover_threshold="${REGION_FAILOVER_RECOVERY_THRESHOLD:-2}"
_recover_secs=$(( _recover_interval * _recover_threshold ))
log "Health monitor should detect recovery within ~${_recover_threshold} cycles (${_recover_secs}s with ${_recover_interval}s interval)"
