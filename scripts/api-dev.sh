#!/usr/bin/env bash
# api-dev.sh — Start the API with repo-local env files exported.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"

log() { echo "[api-dev] $*"; }
die() {
    echo "[api-dev] ERROR: $*" >&2
    exit 1
}

resolve_listen_port() {
    local listen_addr="${LISTEN_ADDR:-0.0.0.0:3001}"
    local normalized="$listen_addr"
    local port

    if [[ "$normalized" == *"://"* ]]; then
        normalized="${normalized#*://}"
        normalized="${normalized%%/*}"
    fi

    port="${normalized##*:}"
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        die "LISTEN_ADDR must include a numeric port (got: ${listen_addr})"
    fi

    printf '%s\n' "$port"
}

if [ -f "$REPO_ROOT/.env.local" ]; then
    load_env_file "$REPO_ROOT/.env.local"
fi

listen_port="$(resolve_listen_port)"
check_port_available "$listen_port" "api LISTEN_ADDR" \
    || die "port $listen_port is already in use (needed for api LISTEN_ADDR ${LISTEN_ADDR:-0.0.0.0:3001})"

# Stage-proof defaults: verification lanes require real token delivery.
# Opt back in for demo-only quickstart runs via API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1.
if [ "${API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION:-}" != "1" ]; then
    unset SKIP_EMAIL_VERIFICATION
fi

# Prefer Mailpit delivery for local browser-lane proofs when it is configured.
# Keep SES available behind explicit API_DEV_ALLOW_SES_EMAIL=1 opt-in.
if [ -n "${MAILPIT_API_URL:-}" ] && [ "${API_DEV_ALLOW_SES_EMAIL:-}" != "1" ]; then
    unset SES_FROM_ADDRESS
    unset SES_REGION
fi

# Default local dev to the in-process Stripe mock so checkout-based fixture
# arrangement remains deterministic even when bootstrap injected live test keys.
# Opt into live Stripe only when explicitly requested.
if [ "${API_DEV_ALLOW_LIVE_STRIPE:-}" != "1" ]; then
    export STRIPE_LOCAL_MODE="${STRIPE_LOCAL_MODE:-1}"
    if [ "${STRIPE_LOCAL_MODE}" = "1" ]; then
        unset STRIPE_SECRET_KEY
        unset STRIPE_TEST_SECRET_KEY
        unset STRIPE_PUBLISHABLE_KEY
        export STRIPE_WEBHOOK_SECRET="${STRIPE_WEBHOOK_SECRET:-whsec_local_dev_secret}"
    fi
fi

export FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"
# Local Flapjack does not expose the internal replication API used by the
# production orchestrator. Keep the task effectively dormant unless a developer
# explicitly opts into testing replication behavior with a shorter interval.
export REPLICATION_CYCLE_INTERVAL_SECS="${REPLICATION_CYCLE_INTERVAL_SECS:-999999}"

mkdir -p "$REPO_ROOT/.local"
printf '%s\n' "$$" > "$REPO_ROOT/.local/api.pid"

cd "$REPO_ROOT"
exec cargo run --manifest-path infra/Cargo.toml -p api "$@"
