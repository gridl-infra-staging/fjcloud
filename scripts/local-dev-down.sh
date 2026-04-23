#!/usr/bin/env bash
# local-dev-down.sh — Tear down local dev services.
#
# Kills flapjack, stops Docker Compose, cleans up PID/log files.
# Idempotent: safe to run even when nothing is running.
#
# Usage:
#   scripts/local-dev-down.sh           # stop services, keep data
#   scripts/local-dev-down.sh --clean   # stop services and remove volumes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/process.sh
source "$SCRIPT_DIR/lib/process.sh"

PID_DIR="$REPO_ROOT/.local"

log() { echo "[local-dev-down] $*"; }

# ---------------------------------------------------------------------------
# 1. Stop flapjack (single-instance and multi-region)
# ---------------------------------------------------------------------------
kill_pid_file "$PID_DIR/flapjack.pid" "flapjack" "flapjack"
# Multi-region flapjack instances (Stage 5)
for pid_file in "$PID_DIR"/flapjack-*.pid; do
    [ -f "$pid_file" ] || continue
    region_name="$(basename "$pid_file" .pid)"
    kill_pid_file "$pid_file" "$region_name" "flapjack"
done

# ---------------------------------------------------------------------------
# 1b. Stop metering agents
# ---------------------------------------------------------------------------
for pid_file in "$PID_DIR"/metering-agent-*.pid; do
    [ -f "$pid_file" ] || continue
    agent_name="$(basename "$pid_file" .pid)"
    kill_pid_file "$pid_file" "$agent_name" "metering-agent"
done

# ---------------------------------------------------------------------------
# 1c. Stop one-command local demo API/web processes
# ---------------------------------------------------------------------------
kill_pid_file "$PID_DIR/api.pid" "api" "cargo"
kill_pid_file "$PID_DIR/web.pid" "web" "node"

# ---------------------------------------------------------------------------
# 2. Stop Docker Compose
# ---------------------------------------------------------------------------
local_compose_args=("compose" "down")
if [[ "${1:-}" == "--clean" ]]; then
    local_compose_args+=("-v")
    log "Removing volumes (--clean)"
fi

(cd "$REPO_ROOT" && docker "${local_compose_args[@]}") 2>&1 | while IFS= read -r line; do
    log "$line"
done

# ---------------------------------------------------------------------------
# 3. Clean up
# ---------------------------------------------------------------------------
rm -f "$PID_DIR"/*.log 2>/dev/null || true
if [ -d "$PID_DIR" ]; then
    rmdir "$PID_DIR" 2>/dev/null || true
fi

log "Local dev stack torn down"
