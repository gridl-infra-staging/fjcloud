#!/usr/bin/env bash
# api-dev.sh — Start the API with repo-local env files exported.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"
# shellcheck source=lib/stripe_checks.sh
source "$SCRIPT_DIR/lib/stripe_checks.sh"

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

# Force one key from an env file into the current process when present.
# This keeps live Stripe key selection anchored to .env.local in proof lanes.
read_env_file_assignment_for_key() {
    local env_file="$1"
    local key="$2"
    local line parse_status

    ENV_FILE_ASSIGNMENT_VALUE=""
    [ -f "$env_file" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ]; then
            if [ "$ENV_ASSIGNMENT_KEY" = "$key" ]; then
                ENV_FILE_ASSIGNMENT_VALUE="$ENV_ASSIGNMENT_VALUE"
                return 0
            fi
            continue
        fi

        if [ "$parse_status" -eq 2 ]; then
            continue
        fi

        echo "ERROR: Unsupported syntax in ${env_file}; only KEY=value assignments are allowed" >&2
        exit 1
    done < "$env_file"

    return 1
}

prefer_env_file_assignment_for_key() {
    local env_file="$1"
    local key="$2"

    read_env_file_assignment_for_key "$env_file" "$key" || return 1
    printf -v "$key" '%s' "$ENV_FILE_ASSIGNMENT_VALUE"
    export "$key"
    return 0
}

# Keep Stripe secret-key resolution anchored to .env.local even when the file
# only defines STRIPE_TEST_SECRET_KEY and the parent shell already exports a
# stale STRIPE_SECRET_KEY that would otherwise win inside resolve_stripe_secret_key.
prefer_env_file_live_stripe_secret_selection() {
    local env_file="$1"
    local secret_present=1
    local test_secret_present=1
    local any_file_secret_assignment_present=0
    local secret_value=""
    local test_secret_value=""

    if read_env_file_assignment_for_key "$env_file" "STRIPE_SECRET_KEY"; then
        any_file_secret_assignment_present=1
        secret_value="$ENV_FILE_ASSIGNMENT_VALUE"
    else
        secret_present=0
    fi

    if read_env_file_assignment_for_key "$env_file" "STRIPE_TEST_SECRET_KEY"; then
        any_file_secret_assignment_present=1
        test_secret_value="$ENV_FILE_ASSIGNMENT_VALUE"
    else
        test_secret_present=0
    fi

    # When the env file mentions either Stripe secret-key slot, clear both
    # inherited values first so an explicit blank assignment fails closed
    # instead of silently reusing a parent-shell secret.
    if [ "$any_file_secret_assignment_present" -eq 1 ]; then
        unset STRIPE_SECRET_KEY
        unset STRIPE_TEST_SECRET_KEY
    fi

    if [ "$secret_present" -eq 1 ] && [ -n "$secret_value" ]; then
        export STRIPE_SECRET_KEY="$secret_value"
    fi

    if [ "$test_secret_present" -eq 1 ] && [ -n "$test_secret_value" ]; then
        export STRIPE_TEST_SECRET_KEY="$test_secret_value"
    fi
}

if [ -f "$REPO_ROOT/.env.local" ]; then
    load_env_file "$REPO_ROOT/.env.local"
    if [ "${API_DEV_ALLOW_LIVE_STRIPE:-}" = "1" ]; then
        prefer_env_file_live_stripe_secret_selection "$REPO_ROOT/.env.local"
        prefer_env_file_assignment_for_key "$REPO_ROOT/.env.local" "STRIPE_PUBLISHABLE_KEY" || true
        prefer_env_file_assignment_for_key "$REPO_ROOT/.env.local" "STRIPE_WEBHOOK_SECRET" || true
    fi
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
# Explicit live-Stripe opt-in must also clear any inherited/local STRIPE_LOCAL_MODE=1
# so downstream billing code does not silently stay pinned to the mock path.
if [ "${API_DEV_ALLOW_LIVE_STRIPE:-}" = "1" ]; then
    unset STRIPE_LOCAL_MODE
    log "Validating live Stripe key before API launch"
    BACKEND_LIVE_GATE=1 check_stripe_key_present
    BACKEND_LIVE_GATE=1 check_stripe_key_live
else
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
