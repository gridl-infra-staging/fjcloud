#!/usr/bin/env bash
# One-command local demo launcher: infra + API + web + seed data + metering.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"

PID_DIR="$REPO_ROOT/.local"
ENV_FILE="$REPO_ROOT/.env.local"

log() { echo "[local-demo] $*"; }

usage() {
    cat <<'EOF'
Usage:
  scripts/local_demo.sh                  Start the full local demo stack
  scripts/local_demo.sh --prepare-env-only
  scripts/local_demo.sh --help
EOF
}

env_has_key() {
    local key="$1"
    [ -f "$ENV_FILE" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE"
}

append_env_if_missing() {
    local key="$1" value="$2"
    if ! env_has_key "$key"; then
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

ensure_demo_env() {
    if [ ! -f "$ENV_FILE" ]; then
        log "Creating .env.local"
        bash "$SCRIPT_DIR/bootstrap-env-local.sh"
    fi

    if ! grep -q "local demo defaults" "$ENV_FILE"; then
        {
            printf '\n'
            printf '# local demo defaults; safe to edit\n'
        } >> "$ENV_FILE"
    fi

    append_env_if_missing "API_BASE_URL" "http://127.0.0.1:3001"
    append_env_if_missing "SKIP_EMAIL_VERIFICATION" "1"
    append_env_if_missing "LOCAL_DEV_FLAPJACK_URL" "http://127.0.0.1:7700"
    append_env_if_missing "FLAPJACK_ADMIN_KEY" "$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY"
    append_env_if_missing "NODE_SECRET_BACKEND" "memory"
    append_env_if_missing "AUTH_RATE_LIMIT_RPM" "120"
    append_env_if_missing "ADMIN_RATE_LIMIT_RPM" "1000"
    append_env_if_missing "TENANT_RATE_LIMIT_RPM" "5000"
    append_env_if_missing "DEFAULT_MAX_QUERY_RPS" "60"
    append_env_if_missing "DEFAULT_MAX_WRITE_RPS" "100"
    append_env_if_missing "DEFAULT_MAX_INDEXES" "100"
    append_env_if_missing "MAILPIT_API_URL" "http://localhost:8025"
    append_env_if_missing "EMAIL_FROM_ADDRESS" "noreply@griddle.local"
    append_env_if_missing "EMAIL_FROM_NAME" "Griddle Local Dev"
    append_env_if_missing "STRIPE_LOCAL_MODE" "1"
    append_env_if_missing "STRIPE_WEBHOOK_SECRET" "whsec_local_dev_secret"
    append_env_if_missing "FLAPJACK_REGIONS" "us-east-1:7700 eu-west-1:7701 eu-central-1:7702"
}

require_command() {
    local cmd="$1" install_hint="$2"
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[local-demo] ERROR: $cmd not found — $install_hint" >&2
        exit 1
    }
}

start_tracked_process() {
    local name="$1" pid_file="$2" log_file="$3"
    shift 3

    if tracked_process_is_running "$pid_file"; then
        log "$name already running (PID $(cat "$pid_file"))"
        return 0
    fi

    log "Starting $name..."
    mkdir -p "$PID_DIR"
    nohup "$@" < /dev/null > "$log_file" 2>&1 &
    echo $! > "$pid_file"
    log "  Log: $log_file"
}

tracked_process_is_running() {
    local pid_file="$1"

    [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null
}

run_demo_stack() {
    require_command docker "install Docker Desktop"
    require_command curl "install curl"

    ensure_demo_env
    load_env_file "$ENV_FILE"

    log "Starting infra"
    bash "$SCRIPT_DIR/local-dev-up.sh"

    start_tracked_process \
        "API" \
        "$PID_DIR/api.pid" \
        "$PID_DIR/api.log" \
        "$SCRIPT_DIR/api-dev.sh"
    wait_for_health "http://127.0.0.1:3001/health" "api" 90 \
        || { log "API failed; see $PID_DIR/api.log"; exit 1; }

    local web_host="127.0.0.1"
    local web_port="5173"
    local web_url="http://${web_host}:${web_port}"
    if ! tracked_process_is_running "$PID_DIR/web.pid"; then
        check_port_available "$web_port" "web" \
            || { log "web port ${web_port} is unavailable; strict-port startup would not be trustworthy"; exit 1; }
    fi

    start_tracked_process \
        "web" \
        "$PID_DIR/web.pid" \
        "$PID_DIR/web.log" \
        "$SCRIPT_DIR/web-dev.sh" \
        --host "$web_host" \
        --port "$web_port" \
        --strictPort
    wait_for_health "$web_url" "web" 90 \
        || { log "web failed; see $PID_DIR/web.log"; exit 1; }

    log "Seeding customers, indexes, sample docs, usage, replicas"
    bash "$SCRIPT_DIR/seed_local.sh"

    log "Starting multi-region metering agents"
    bash "$SCRIPT_DIR/start-metering.sh" --multi-region

    log ""
    log "Ready"
    log "  App:       $web_url"
    log "  Admin:     $web_url/admin"
    log "  Mailpit:   http://localhost:8025"
    log "  Users:     dev@example.com / localdev-password-1234"
    log "             free@example.com / localdev-password-1234"
    log "  Stop:      scripts/local-dev-down.sh"
}

case "${1:-}" in
    "")
        run_demo_stack
        ;;
    --prepare-env-only)
        ensure_demo_env
        log "Prepared $ENV_FILE"
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
