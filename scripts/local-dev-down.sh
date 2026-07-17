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
# shellcheck source=lib/compose_project.sh
source "$SCRIPT_DIR/lib/compose_project.sh"
# shellcheck source=lib/docker.sh
source "$SCRIPT_DIR/lib/docker.sh"

PID_DIR="$REPO_ROOT/.local"

log() { echo "[local-dev-down] $*"; }

# Match the project namespace local-dev-up.sh used to bring containers up;
# otherwise `docker compose down` would target the wrong project (default
# basename) and leave the worktree's containers running.
export COMPOSE_PROJECT_NAME="$(resolve_compose_project_name "$REPO_ROOT")"

# ---------------------------------------------------------------------------
# 1. Stop flapjack (single-instance and multi-region)
# ---------------------------------------------------------------------------
kill_pid_file "$PID_DIR/flapjack.pid" "flapjack" "flapjack" "*flapjack*"
# Multi-region flapjack instances (Stage 5)
for pid_file in "$PID_DIR"/flapjack-*.pid; do
    [ -f "$pid_file" ] || continue
    region_name="$(basename "$pid_file" .pid)"
    kill_pid_file "$pid_file" "$region_name" "flapjack" "*flapjack*"
done

# ---------------------------------------------------------------------------
# 1b. Stop metering agents
# ---------------------------------------------------------------------------
for pid_file in "$PID_DIR"/metering-agent-*.pid; do
    [ -f "$pid_file" ] || continue
    agent_name="$(basename "$pid_file" .pid)"
    # start-metering.sh backgrounds `cargo run`, so the tracked PID can be
    # either Cargo's wrapper or the final fj-metering-agent binary depending
    # on timing. Accept the wrapper only when its full argv proves it is this
    # repo's metering-agent launch, preserving the stale-PID guard.
    kill_pid_file "$pid_file" "$agent_name" "metering-agent" "*metering-agent*"
done

# ---------------------------------------------------------------------------
# 1c. Stop one-command local demo API/web processes
# ---------------------------------------------------------------------------
# `api-dev.sh` ends with `exec cargo run -p api` and `web-dev.sh` ends
# with `exec npm run dev`. Once the exec'd process starts, the live
# `comm` is `fjcloud-api` / `npm run dev --host ...` respectively —
# NOT `cargo` / `node`. The kill_pid_file safety check substring-matches
# against the live `comm`, so passing `cargo`/`node` caused both teardowns
# to skip-and-keep orphan processes (anchored 2026-06-02).
kill_pid_file "$PID_DIR/api.pid" "api" "fjcloud-api" "*fjcloud-api*"
kill_pid_file "$PID_DIR/web.pid" "web" "npm" "*npm*"

# ---------------------------------------------------------------------------
# 2. Stop Docker Compose
# ---------------------------------------------------------------------------
# Best-effort: if docker is offline (colima socket rot after sleep, OrbStack
# stuck Starting, etc.) we still want to have killed the tracked host PIDs
# above. Skip the compose block instead of dying. The compose-managed
# containers will remain "stopped from docker's POV but with no daemon to
# stop them" — they'll get cleaned up when docker comes back via the next
# `up`/`down` cycle.
if ensure_docker_daemon_or_warn; then
    local_compose_args=("compose" "down")
    if [[ "${1:-}" == "--clean" ]]; then
        local_compose_args+=("-v")
        log "Removing volumes (--clean)"
    fi

    (cd "$REPO_ROOT" && docker "${local_compose_args[@]}") 2>&1 | while IFS= read -r line; do
        log "$line"
    done
else
    log "skipping 'docker compose down' — daemon unreachable (tracked PIDs above were still killed)"
fi

if [[ "${1:-}" == "--clean" ]]; then
    # local-dev-up.sh stores Flapjack state outside Docker volumes. Without
    # clearing these repo-local data dirs, a "clean" launch can repopulate a
    # fresh Postgres volume from stale search-engine fixture state.
    for data_dir in \
        "$PID_DIR/flapjack-data" \
        "$PID_DIR/flapjack-data-us-east-1" \
        "$PID_DIR/flapjack-data-eu-west-1" \
        "$PID_DIR/flapjack-data-eu-central-1"
    do
        if [ -e "$data_dir" ]; then
            rm -rf "$data_dir"
            log "Removed $(basename "$data_dir")"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 3. Clean up
# ---------------------------------------------------------------------------
rm -f "$PID_DIR"/*.log 2>/dev/null || true
if [ -d "$PID_DIR" ]; then
    rmdir "$PID_DIR" 2>/dev/null || true
fi

log "Local dev stack torn down"
