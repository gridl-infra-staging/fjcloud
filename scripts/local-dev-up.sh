#!/usr/bin/env bash
# local-dev-up.sh — Start the local development environment.
#
# Starts Docker Compose Postgres, runs migrations, starts Flapjack on port 7700,
# and prints instructions for starting the API and web processes manually.
#
# Prerequisites: docker, curl, .env.local at repo root.
# Optional: FLAPJACK_DEV_DIR pointing to flapjack_dev repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/migrate.sh
source "$SCRIPT_DIR/lib/migrate.sh"
# shellcheck source=lib/db_url.sh
source "$SCRIPT_DIR/lib/db_url.sh"
# shellcheck source=lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"
# shellcheck source=lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"

FLAPJACK_PORT="${FLAPJACK_PORT:-7700}"

PID_DIR="$REPO_ROOT/.local"
FLAPJACK_PID="$PID_DIR/flapjack.pid"
FLAPJACK_LOG="$PID_DIR/flapjack.log"
FLAPJACK_DATA_DIR="${FLAPJACK_DATA_DIR:-$PID_DIR/flapjack-data}"

log() { echo "[local-dev-up] $*"; }
die() {
    echo "[local-dev-up] ERROR: $*" >&2
    exit 1
}

wait_until_success() {
    local timeout_seconds="$1"
    local sleep_seconds="$2"
    local check_function="$3"
    local elapsed=0
    shift 3

    while [ "$elapsed" -lt "$timeout_seconds" ]; do
        if "$check_function" "$@"; then
            return 0
        fi
        sleep "$sleep_seconds"
        elapsed=$((elapsed + sleep_seconds))
    done

    return 1
}

# Start an optional Docker Compose service and health-check it.
# Returns 0 if healthy, 1 if not. This helper never exits the script so callers
# can choose whether degraded startup is acceptable for their workflow.
start_optional_service() {
    local service="$1" health_url="$2" timeout="${3:-15}"
    log "Starting ${service}..."
    (cd "$REPO_ROOT" && docker compose up -d "$service") 2>&1 | while IFS= read -r line; do log "$line"; done
    if wait_for_health "$health_url" "$service" "$timeout"; then
        return 0
    fi
    return 1
}

seaweedfs_s3_is_reachable() {
    local port="$1"
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/" 2>/dev/null || true)"
    [ "$code" = "200" ] || [ "$code" = "403" ]
}

start_seaweedfs_service() {
    local port="$1" timeout="${2:-15}"
    log "Starting seaweedfs..."
    (cd "$REPO_ROOT" && docker compose up -d seaweedfs) 2>&1 | while IFS= read -r line; do log "$line"; done
    if wait_until_success "$timeout" 1 seaweedfs_s3_is_reachable "$port"; then
        log "seaweedfs is healthy (http://localhost:${port}/)"
        return 0
    fi
    log "seaweedfs failed health check after ${timeout}s (http://localhost:${port}/)"
    return 1
}

start_postgres_service() {
    log "Starting Postgres..."
    (cd "$REPO_ROOT" && LOCAL_DB_PORT="$DB_PORT" docker compose up -d postgres)
}

postgres_server_is_ready() {
    # Use a server-level probe so stale app-role credentials do not block
    # readiness detection before compatibility recovery can run.
    (cd "$REPO_ROOT" && docker compose exec -T postgres pg_isready -U postgres -d postgres) >/dev/null 2>&1
}

wait_for_postgres_server() {
    log "Waiting for Postgres to be ready..."
    wait_until_success 30 1 postgres_server_is_ready || return 1
    log "Postgres is ready"
}

postgres_volume_matches_env() {
    local db_user="$1"
    local db_password="$2"
    local db_name="$3"

    (cd "$REPO_ROOT" && docker compose exec -T postgres \
        env "PGPASSWORD=$db_password" \
        psql -h 127.0.0.1 -U "$db_user" -d "$db_name" -c "SELECT 1") >/dev/null 2>&1
}

wait_for_postgres_app_credentials() {
    wait_until_success 15 1 postgres_volume_matches_env "$@"
}

require_database_url_part() {
    local extractor="$1"
    local error_message="$2"
    local value

    value="$(require_db_url_part "$DATABASE_URL" "$extractor")" || die "$error_message"
    printf '%s\n' "$value"
}

ensure_postgres_volume_matches_env() {
    local db_user="$1"
    local db_password="$2"
    local db_name="$3"

    if wait_for_postgres_app_credentials "$db_user" "$db_password" "$db_name"; then
        return 0
    fi

    log "Existing Postgres volume is incompatible with $(redact_db_url "$DATABASE_URL"); recreating it with current Docker credentials"
    "$SCRIPT_DIR/local-dev-down.sh" --clean
    start_postgres_service
    wait_for_postgres_server \
        || die "Postgres failed to become ready after recreating the local volume"

    wait_for_postgres_app_credentials "$db_user" "$db_password" "$db_name" \
        || die "Postgres volume still does not match $(redact_db_url "$DATABASE_URL") after recreation"
}

run_container_migrations() {
    local source_migrations_dir="$1"
    local container_migrations_dir="$2"

    run_docker_postgres_migrations \
        "$REPO_ROOT" \
        "$source_migrations_dir" \
        "$container_migrations_dir" \
        "$DB_USER" \
        "$DB_PASSWORD" \
        "$DB_NAME"
}

# ---------------------------------------------------------------------------
# 1. Check prerequisites
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 \
    || die "docker not found — install Docker Desktop"
command -v curl >/dev/null 2>&1 \
    || die "curl not found — install curl"
# psql is not required on the host — migrations run via docker compose exec

if [ ! -f "$REPO_ROOT/.env.local" ]; then
    log "No .env.local found — attempting bootstrap..."
    if bash "$SCRIPT_DIR/bootstrap-env-local.sh"; then
        log "Bootstrap created .env.local successfully"
    else
        die ".env.local not found and bootstrap failed — run: scripts/bootstrap-env-local.sh"
    fi
fi

load_env_file "$REPO_ROOT/.env.local"

FLAPJACK_DEV_DIR="$(resolve_default_flapjack_dev_dir)"

[ -n "${DATABASE_URL:-}" ] \
    || die "DATABASE_URL is required in .env.local"
if [ -n "${FLAPJACK_ADMIN_KEY:-}" ]; then
    FLAPJACK_ADMIN_KEY_SUMMARY="explicit override set"
else
    FLAPJACK_ADMIN_KEY="$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY"
    FLAPJACK_ADMIN_KEY_SUMMARY="default fj_local local-dev key set"
fi

DB_USER="$(require_database_url_part db_url_user "DATABASE_URL must include a username")"
DB_PASSWORD="$(require_database_url_part db_url_password "DATABASE_URL must include a password")"
DB_NAME="$(require_database_url_part db_url_database "DATABASE_URL must include a database name")"
DB_HOST="$(require_database_url_part db_url_host "DATABASE_URL must include a hostname")"
DB_PORT="$(require_database_url_part db_url_port "DATABASE_URL must include a valid port")"

# ---------------------------------------------------------------------------
# 2. Clean stale state
# ---------------------------------------------------------------------------
"$SCRIPT_DIR/local-dev-down.sh" 2>/dev/null || true
mkdir -p "$PID_DIR"

# ---------------------------------------------------------------------------
# 3. Start Postgres via Docker Compose
# ---------------------------------------------------------------------------
start_postgres_service
if ! wait_for_postgres_server; then
    die "Postgres failed to become ready after 30s"
fi
ensure_postgres_volume_matches_env "$DB_USER" "$DB_PASSWORD" "$DB_NAME"

# ---------------------------------------------------------------------------
# 3b. Start SeaweedFS + Mailpit (optional, non-fatal)
# ---------------------------------------------------------------------------
# Both services are defined in docker-compose.yml as permanent (not profile-gated).
# Failures are non-fatal — the API falls back to InMemoryObjectStore / NoopEmailService.
# These flags are the single startup source of truth for the summary output below;
# we intentionally avoid re-probing Docker state in section 6.
SEAWEEDFS_HEALTHY=0
MAILPIT_HEALTHY=0

local_s3_port="${LOCAL_S3_PORT:-8333}"
if start_seaweedfs_service "$local_s3_port" 15; then
    SEAWEEDFS_HEALTHY=1
    # SeaweedFS now runs with a deterministic local S3 identity. Bucket creation
    # is delegated to the signed Rust cold-storage proof instead of an unsigned
    # bootstrap curl, so real AWS credentials cannot accidentally affect local S3.
    log "S3 endpoint reachable at http://localhost:${local_s3_port}"
fi

if start_optional_service "mailpit" "http://localhost:${LOCAL_MAILPIT_UI_PORT:-8025}/api/v1/info" 15; then
    MAILPIT_HEALTHY=1
fi

# ---------------------------------------------------------------------------
# 4. Run migrations
# ---------------------------------------------------------------------------
log "Applying migrations to: $(redact_db_url "$DATABASE_URL")"
CONTAINER_MIGRATIONS_DIR="/migrations"
run_container_migrations "$REPO_ROOT/infra/migrations" "$CONTAINER_MIGRATIONS_DIR" \
    || die "migrations failed"

# ---------------------------------------------------------------------------
# 5. Start Flapjack (if available)
# ---------------------------------------------------------------------------
# Multi-region mode: FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701 eu-central-1:7702"
# Single-instance mode (default): FLAPJACK_SINGLE_INSTANCE=1 or FLAPJACK_REGIONS unset
FLAPJACK_BIN=""
FLAPJACK_BIN="$(find_flapjack_binary "$FLAPJACK_DEV_DIR" || true)"

# Helper to start one Flapjack instance with the given region, port, and data dir.
start_one_flapjack() {
    local region="$1" port="$2" data_dir="$3"
    local pid_file="$PID_DIR/flapjack-${region}.pid"
    local log_file="$PID_DIR/flapjack-${region}.log"

    check_port_available "$port" "flapjack-${region}" \
        || die "port $port is already in use (needed for flapjack-${region})"

    log "Starting flapjack (${region}) on port ${port}..."
    mkdir -p "$data_dir"

    FLAPJACK_ADMIN_KEY="$FLAPJACK_ADMIN_KEY" \
        nohup "$FLAPJACK_BIN" \
            --port "$port" \
            --data-dir "$data_dir" \
            < /dev/null > "$log_file" 2>&1 &
    echo $! > "$pid_file"

    wait_for_health "http://127.0.0.1:${port}/health" "flapjack-${region}" 15 \
        || die "flapjack-${region} did not become healthy"
}

FLAPJACK_STARTED_REGIONS=""

if [ -n "$FLAPJACK_BIN" ] && [ -x "$FLAPJACK_BIN" ]; then
    log "Flapjack binary: $FLAPJACK_BIN"
    if [ "${FLAPJACK_SINGLE_INSTANCE:-}" = "1" ] || [ -z "${FLAPJACK_REGIONS:-}" ]; then
        # Single-instance mode (backward compatible).
        start_one_flapjack "default" "$FLAPJACK_PORT" "$FLAPJACK_DATA_DIR"
        # Symlink the default PID for backward compat with old local-dev-down.sh.
        ln -sf "flapjack-default.pid" "$FLAPJACK_PID"
        FLAPJACK_STARTED_REGIONS="default:${FLAPJACK_PORT}"
    else
        # Multi-region mode: start one Flapjack per region.
        for region_port in $FLAPJACK_REGIONS; do
            region="${region_port%%:*}"
            port="${region_port##*:}"
            data_dir="$PID_DIR/flapjack-data-${region}"
            start_one_flapjack "$region" "$port" "$data_dir"
            FLAPJACK_STARTED_REGIONS="${FLAPJACK_STARTED_REGIONS:+${FLAPJACK_STARTED_REGIONS} }${region}:${port}"
        done
    fi
else
    log "WARNING: flapjack binary not found — skipping flapjack startup"
    log "  Set FLAPJACK_DEV_DIR to point to the flapjack_dev repo"
fi

# ---------------------------------------------------------------------------
# 6. Print startup summary
# ---------------------------------------------------------------------------
log ""
log "Local dev infrastructure is up!"
log "  Postgres:       ${DB_HOST}:${DB_PORT} (via Docker Compose)"
if [ -n "$FLAPJACK_STARTED_REGIONS" ]; then
    for region_port in $FLAPJACK_STARTED_REGIONS; do
        region="${region_port%%:*}"
        port="${region_port##*:}"
        log "  Flapjack ${region}: http://localhost:${port}"
    done
fi
# Show SeaweedFS/Mailpit only when health checks passed during startup.
if [ "$SEAWEEDFS_HEALTHY" = "1" ]; then
    log "  SeaweedFS S3:   http://localhost:${LOCAL_S3_PORT:-8333}"
fi
if [ "$MAILPIT_HEALTHY" = "1" ]; then
    log "  Mailpit UI:     http://localhost:${LOCAL_MAILPIT_UI_PORT:-8025}"
fi
log "  Admin key:      (${FLAPJACK_ADMIN_KEY_SUMMARY})"
log "  Database:       $(redact_db_url "$DATABASE_URL")"
log ""
log "Start the API:"
log "  scripts/api-dev.sh"
log ""
log "Start the web frontend:"
log "  scripts/web-dev.sh"
log ""
log "After seeding (scripts/seed_local.sh), start metering:"
log "  scripts/start-metering.sh          # single-region"
log "  scripts/start-metering.sh --multi-region  # multi-region"
