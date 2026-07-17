#!/usr/bin/env bash
# start-metering.sh — Start the metering agent for local dev.
#
# Must run AFTER seed_local.sh (needs a real customer UUID from the database).
# The metering agent scrapes Flapjack /metrics, computes deltas, and writes
# usage_records to Postgres. Runs as a background process with PID tracking.
#
# Usage:
#   scripts/start-metering.sh                    # single agent for default Flapjack
#   scripts/start-metering.sh --multi-region     # one agent per region (Stage 5)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"

log() { echo "[start-metering] $*"; }
die() { echo "[start-metering] ERROR: $*" >&2; exit 1; }

PID_DIR="${REPO_ROOT}/.local"
mkdir -p "$PID_DIR"

load_env_file "$REPO_ROOT/.env.local"

[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is required in .env.local"
FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"

# ---------------------------------------------------------------------------
# Look up the shared-plan customer UUID from the database.
# This is the customer seeded by seed_local.sh with billing_plan='shared'.
# ---------------------------------------------------------------------------
if command -v psql >/dev/null 2>&1; then
    CUSTOMER_ID=$(PSQLRC=/dev/null psql "$DATABASE_URL" -tAc \
        "SELECT id FROM customers WHERE billing_plan = 'shared' LIMIT 1" 2>/dev/null)
elif command -v docker >/dev/null 2>&1 \
    && (cd "$REPO_ROOT" && docker compose ps --status running postgres >/dev/null 2>&1); then
    # Fall back to docker compose psql when host psql is unavailable.
    CUSTOMER_ID=$(cd "$REPO_ROOT" && docker compose exec -T postgres \
        psql -U griddle -d fjcloud_dev -tAc \
        "SELECT id FROM customers WHERE billing_plan = 'shared' LIMIT 1" 2>/dev/null)
else
    die "psql not found and Docker Postgres is unavailable — cannot look up customer UUID"
fi

# Trim whitespace from psql output.
CUSTOMER_ID="$(echo "$CUSTOMER_ID" | tr -d '[:space:]')"
[ -n "$CUSTOMER_ID" ] || die "no shared customer found — run seed_local.sh first"
log "Found shared customer: $CUSTOMER_ID"

# ---------------------------------------------------------------------------
# Start metering agent(s)
# ---------------------------------------------------------------------------
start_metering_agent() {
    local region="$1"
    local flapjack_url="$2"
    local health_port="$3"
    local node_id="local-node-${region}"
    local pid_file="$PID_DIR/metering-agent-${region}.pid"
    local log_file="$PID_DIR/metering-agent-${region}.log"

    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
        log "Metering agent for ${region} already running (PID $(cat "$pid_file"))"
        return 0
    fi

    log "Starting metering agent for ${region} (flapjack=${flapjack_url}, health=:${health_port})..."

    DATABASE_URL="$DATABASE_URL" \
    FLAPJACK_URL="$flapjack_url" \
    FLAPJACK_API_KEY="$FLAPJACK_ADMIN_KEY" \
    CUSTOMER_ID="$CUSTOMER_ID" \
    NODE_ID="$node_id" \
    REGION="$region" \
    SCRAPE_INTERVAL_SECS=30 \
    HEALTH_PORT="$health_port" \
        nohup cargo run --manifest-path "$REPO_ROOT/infra/Cargo.toml" \
            -p metering-agent > "$log_file" 2>&1 &
    echo $! > "$pid_file"

    log "Metering agent started for ${region} (PID $(cat "$pid_file"))"
    log "  Log: $log_file"
    log "  Health: http://127.0.0.1:${health_port}/health"
}

if [ "${1:-}" = "--multi-region" ]; then
    # Stage 5: one metering agent per Flapjack region.
    # FLAPJACK_REGIONS uses the standard 2-field format (region:port).
    # Health ports are derived automatically starting at 9091.
    FLAPJACK_REGIONS="${FLAPJACK_REGIONS:-us-east-1:7700 eu-west-1:7701 eu-central-1:7702}"
    health_port=9091
    for region_port in $FLAPJACK_REGIONS; do
        region="${region_port%%:*}"
        port="${region_port##*:}"
        start_metering_agent "$region" "http://127.0.0.1:${port}" "$health_port"
        health_port=$((health_port + 1))
    done
else
    # Single-region mode: one metering agent for the default Flapjack.
    flapjack_port="${FLAPJACK_PORT:-7700}"
    start_metering_agent "us-east-1" "http://127.0.0.1:${flapjack_port}" "9091"
fi
