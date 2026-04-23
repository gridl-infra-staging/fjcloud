#!/usr/bin/env bash
# integration-up.sh — Bring up an isolated integration test stack.
#
# Creates fjcloud_integration_test DB, runs migrations, builds binaries,
# starts flapjack on port 7799, starts fjcloud API on port 3099, health-checks both.
#
# Prerequisites: Postgres 16 running locally, flapjack_dev repo at FLAPJACK_DEV_DIR.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env vars)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$REPO_ROOT/infra"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/integration_stack_env.sh
source "$SCRIPT_DIR/lib/integration_stack_env.sh"
# shellcheck source=lib/migrate.sh
source "$SCRIPT_DIR/lib/migrate.sh"
# shellcheck source=lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"
init_integration_env_defaults

export FLAPJACK_PORT="${FLAPJACK_PORT:-7799}"
export API_PORT="${API_PORT:-3099}"
export INTEGRATION_S3_PORT="${INTEGRATION_S3_PORT:-3102}"
export FLAPJACK_DEV_DIR="${FLAPJACK_DEV_DIR:-}"
INTEGRATION_RUNTIME_DB_URL="$INTEGRATION_DB_URL"

PID_DIR="$REPO_ROOT/.integration"
FLAPJACK_PID="$PID_DIR/flapjack.pid"
API_PID="$PID_DIR/api.pid"
FLAPJACK_LOG="$PID_DIR/flapjack.log"
API_LOG="$PID_DIR/api.log"
FLAPJACK_DATA_DIR="$PID_DIR/flapjack-data"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[integration-up] $*"; }
die_with_reason() {
    local reason_code="$1"
    local message="$2"
    echo "REASON: $reason_code" >&2
    echo "[integration-up] ERROR: $message" >&2
    exit 1
}
die() { die_with_reason "runtime_error" "$*"; }

read_env_assignment() {
    local env_file="$1"
    local target_key="$2"
    local line parse_status

    [ -f "$env_file" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        if parse_env_assignment_line "$line"; then
            [ "$ENV_ASSIGNMENT_KEY" = "$target_key" ] || continue
            printf '%s\n' "$ENV_ASSIGNMENT_VALUE"
            return 0
        fi

        parse_status=$?
        if [ "$parse_status" -eq 2 ]; then
            continue
        fi
    done < "$env_file"

    return 1
}

resolve_local_dev_database_url() {
    if [ -n "${DATABASE_URL:-}" ]; then
        printf '%s\n' "$DATABASE_URL"
        return 0
    fi

    read_env_assignment "$REPO_ROOT/.env.local" DATABASE_URL
}

env_or_repo_value() {
    local key="$1"
    local fallback="${2:-}"
    local repo_value

    if [ -n "${!key:-}" ]; then
        printf '%s\n' "${!key}"
        return 0
    fi

    if repo_value="$(read_env_assignment "$REPO_ROOT/.env.local" "$key" 2>/dev/null)"; then
        printf '%s\n' "$repo_value"
        return 0
    fi

    printf '%s\n' "$fallback"
}

generate_hex_secret() {
    local byte_count="${1:-32}"

    python3 - "$byte_count" <<'PY'
import secrets
import sys

print(secrets.token_hex(int(sys.argv[1])))
PY
}

redact_secret() {
    local secret_value="${1:-}"

    if [ -z "$secret_value" ]; then
        printf '<unset>\n'
        return 0
    fi

    printf '<redacted:%s chars>\n' "${#secret_value}"
}

init_integration_db_access() {
    INTEGRATION_DB_ACCESS_MODE=""
    INTEGRATION_DB_ACCESS_FAILURE_HINT=""
    INTEGRATION_DOCKER_DB_USER=""
    INTEGRATION_DOCKER_DB_PASSWORD=""
    INTEGRATION_RUNTIME_DB_URL="$INTEGRATION_DB_URL"

    if command -v psql >/dev/null 2>&1; then
        INTEGRATION_DB_ACCESS_MODE="host-psql"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    if ! (cd "$REPO_ROOT" && docker compose ps --status running postgres >/dev/null 2>&1); then
        return 1
    fi

    # Docker Postgres IS running — failures from here get specific hints
    # so operators see the real blocker, not a generic "install psql" message.
    local source_db_url
    source_db_url="$(resolve_local_dev_database_url)" || {
        INTEGRATION_DB_ACCESS_FAILURE_HINT="Docker Compose Postgres is running but DATABASE_URL is not set in env or .env.local — set DATABASE_URL in .env.local for docker fallback access"
        return 1
    }

    INTEGRATION_DOCKER_DB_USER="$(db_url_user "$source_db_url")" || {
        INTEGRATION_DB_ACCESS_FAILURE_HINT="unable to parse database username from DATABASE_URL for docker compose fallback"
        return 1
    }
    INTEGRATION_DOCKER_DB_PASSWORD="$(db_url_password "$source_db_url")" || {
        INTEGRATION_DB_ACCESS_FAILURE_HINT="unable to parse database password from DATABASE_URL for docker compose fallback"
        return 1
    }
    local docker_db_host docker_db_port
    docker_db_host="$(db_url_host "$source_db_url")" || {
        INTEGRATION_DB_ACCESS_FAILURE_HINT="unable to parse database host from DATABASE_URL for docker compose fallback"
        return 1
    }
    docker_db_port="$(db_url_port "$source_db_url")" || {
        INTEGRATION_DB_ACCESS_FAILURE_HINT="unable to parse database port from DATABASE_URL for docker compose fallback"
        return 1
    }

    if [ -n "$INTEGRATION_DOCKER_DB_PASSWORD" ]; then
        INTEGRATION_RUNTIME_DB_URL="postgres://${INTEGRATION_DOCKER_DB_USER}:${INTEGRATION_DOCKER_DB_PASSWORD}@${docker_db_host}:${docker_db_port}/${INTEGRATION_DB}"
    else
        INTEGRATION_RUNTIME_DB_URL="postgres://${INTEGRATION_DOCKER_DB_USER}@${docker_db_host}:${docker_db_port}/${INTEGRATION_DB}"
    fi
    INTEGRATION_DB_ACCESS_MODE="docker-compose-psql"
    return 0
}

integration_db_prerequisite_message() {
    if [ -n "${INTEGRATION_DB_ACCESS_MODE:-}" ]; then
        case "$INTEGRATION_DB_ACCESS_MODE" in
            host-psql)
                echo "psql"
                ;;
            docker-compose-psql)
                echo "docker compose postgres"
                ;;
        esac
        return 0
    fi

    echo "psql not found and Docker Compose Postgres fallback is unavailable"
}

run_integration_psql() {
    local db_name="$1"
    shift

    case "${INTEGRATION_DB_ACCESS_MODE:-}" in
        host-psql)
            PSQLRC=/dev/null psql \
                -h "$INTEGRATION_DB_HOST" \
                -p "$INTEGRATION_DB_PORT" \
                -U "$INTEGRATION_DB_USER" \
                -d "$db_name" \
                "$@"
            ;;
        docker-compose-psql)
            (
                cd "$REPO_ROOT" || exit 1
                PSQLRC=/dev/null docker compose exec -T postgres \
                    env "PGPASSWORD=$INTEGRATION_DOCKER_DB_PASSWORD" \
                    psql -h 127.0.0.1 -U "$INTEGRATION_DOCKER_DB_USER" -d "$db_name" "$@"
            )
            ;;
        *)
            die_with_reason "prerequisite_missing" "integration database access is not configured"
            ;;
    esac
}

run_integration_migrations() {
    if [ "${INTEGRATION_DB_ACCESS_MODE:-}" = "host-psql" ]; then
        run_migrations "$INTEGRATION_RUNTIME_DB_URL" "$INFRA_DIR/migrations"
        return $?
    fi

    local migration found_any=false
    for migration in "$INFRA_DIR/migrations"/*.sql; do
        [ -e "$migration" ] || continue
        found_any=true
        log "Applying: $(basename "$migration")"
        if ! run_integration_psql "$INTEGRATION_DB" -v ON_ERROR_STOP=1 < "$migration" >/dev/null; then
            log "Failed: $(basename "$migration")"
            return 1
        fi
    done

    if [ "$found_any" != true ]; then
        log "No SQL migration files found in: $INFRA_DIR/migrations"
        return 1
    fi

    log "All migrations applied"
}

# shellcheck source=lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"

check_prerequisites() {
    local ok=true
    if init_integration_db_access; then
        log "prerequisite ok: $(integration_db_prerequisite_message)"
    else
        # Use the specific failure hint when available (e.g. Docker Postgres
        # running but DATABASE_URL missing); fall back to the generic install
        # guidance only when no docker fallback was attempted.
        if [ -n "${INTEGRATION_DB_ACCESS_FAILURE_HINT:-}" ]; then
            log "ERROR: $INTEGRATION_DB_ACCESS_FAILURE_HINT"
        else
            log "ERROR: $(prerequisite_missing_message psql)"
        fi
        ok=false
    fi

    for cmd in cargo curl; do
        if command -v "$cmd" >/dev/null 2>&1; then
            log "prerequisite ok: $cmd"
        else
            log "ERROR: $(prerequisite_missing_message "$cmd")"
            ok=false
        fi
    done
    validate_integration_db_name "$INTEGRATION_DB" \
        || { log "ERROR: INTEGRATION_DB must be a safe PostgreSQL identifier (letters, numbers, underscore): '$INTEGRATION_DB'"; ok=false; }

    # Confirm that a flapjack admin key is configured without echoing the
    # secret into terminal history or CI logs.
    local effective_admin_key
    effective_admin_key="$(env_or_repo_value FLAPJACK_ADMIN_KEY "$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY")"
    log "effective FLAPJACK_ADMIN_KEY: $(redact_secret "$effective_admin_key")"

    if [ "$ok" = true ]; then
        log "All prerequisites satisfied"
        return 0
    else
        echo "REASON: prerequisite_missing" >&2
        return 1
    fi
}

prerequisite_missing_message() {
    local cmd="$1"
    case "$cmd" in
        cargo)
            echo "cargo not found — install Rust toolchain via https://rustup.rs"
            ;;
        curl)
            echo "curl not found — install curl (brew install curl on macOS)"
            ;;
        psql)
            echo "psql not found — install PostgreSQL client (brew install postgresql on macOS), or run Docker Compose Postgres with a valid DATABASE_URL/.env.local for fallback access"
            ;;
        *)
            echo "$cmd not found"
            ;;
    esac
}


# Handle --check-prerequisites flag: validate and exit early
if [[ "${1:-}" == "--check-prerequisites" ]]; then
    check_prerequisites || exit 1
    exit 0
fi

if [ -z "${FLAPJACK_DEV_DIR:-}" ]; then
    FLAPJACK_DEV_DIR="$(read_env_assignment "$REPO_ROOT/.env.local" FLAPJACK_DEV_DIR 2>/dev/null || true)"
fi
if [ -z "${FLAPJACK_DEV_DIR_CANDIDATES:-}" ]; then
    FLAPJACK_DEV_DIR_CANDIDATES="$(read_env_assignment "$REPO_ROOT/.env.local" FLAPJACK_DEV_DIR_CANDIDATES 2>/dev/null || true)"
fi
FLAPJACK_DEV_DIR="$(resolve_default_flapjack_dev_dir)"
export FLAPJACK_DEV_DIR
if ! init_integration_db_access; then
    if [ -n "${INTEGRATION_DB_ACCESS_FAILURE_HINT:-}" ]; then
        die_with_reason "prerequisite_missing" "$INTEGRATION_DB_ACCESS_FAILURE_HINT"
    else
        die_with_reason "prerequisite_missing" "$(prerequisite_missing_message psql)"
    fi
fi
command -v cargo >/dev/null 2>&1 || die_with_reason "prerequisite_missing" "$(prerequisite_missing_message cargo)"
command -v curl >/dev/null 2>&1 || die_with_reason "prerequisite_missing" "$(prerequisite_missing_message curl)"
validate_integration_db_name "$INTEGRATION_DB" \
    || die_with_reason "prerequisite_missing" "INTEGRATION_DB must be a safe PostgreSQL identifier (letters, numbers, underscore): '$INTEGRATION_DB'"

# Kill any stale processes and reset the prior integration stack before recreating the DB.
"$SCRIPT_DIR/integration-down.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1. Create/reset test database
# ---------------------------------------------------------------------------
log "Setting up database: $INTEGRATION_DB"
if ! run_integration_psql postgres \
    -tc "SELECT 1 FROM pg_database WHERE datname = '$INTEGRATION_DB'" \
    | grep -q 1; then
    run_integration_psql postgres \
        -c "CREATE DATABASE \"$INTEGRATION_DB\"" \
        || die_with_reason "db_creation_failed" "failed to create integration database '$INTEGRATION_DB'"
fi

# Run migrations
log "Running migrations..."
run_integration_migrations \
    || die_with_reason "migration_failed" "migrations failed"

# ---------------------------------------------------------------------------
# 2. Build binaries
# ---------------------------------------------------------------------------
log "Building fjcloud API..."
(cd "$INFRA_DIR" && cargo build -p api 2>&1 | tail -3)
API_BIN="$INFRA_DIR/target/debug/api"
[ -f "$API_BIN" ] || die_with_reason "binary_not_found" "API binary not found at $API_BIN"

FLAPJACK_BIN=""
if [ -d "$FLAPJACK_DEV_DIR" ]; then
    log "Building flapjack..."
    FLAPJACK_BIN="$(find_flapjack_binary "$FLAPJACK_DEV_DIR" || true)"
    if [ -z "$FLAPJACK_BIN" ]; then
        # Try building
        (cd "$FLAPJACK_DEV_DIR" && cargo build -p flapjack-http 2>&1 | tail -3) || true
        FLAPJACK_BIN="$(find_flapjack_binary "$FLAPJACK_DEV_DIR" || true)"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Start services
# ---------------------------------------------------------------------------
mkdir -p "$PID_DIR"
check_port_available "$API_PORT" "fjcloud API" \
    || die_with_reason "port_in_use" "port $API_PORT is already in use (needed for fjcloud API)"
check_port_available "$INTEGRATION_S3_PORT" "fjcloud S3 API" \
    || die_with_reason "port_in_use" "port $INTEGRATION_S3_PORT is already in use (needed for fjcloud S3 API)"

# Resolve the flapjack admin key before the conditional so the API always
# receives a valid key, even when the flapjack binary is not available.
INTEGRATION_FLAPJACK_ADMIN_KEY="$(env_or_repo_value FLAPJACK_ADMIN_KEY "$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY")"

# Start flapjack (if binary available)
if [ -n "$FLAPJACK_BIN" ] && [ -x "$FLAPJACK_BIN" ]; then
    check_port_available "$FLAPJACK_PORT" "flapjack" \
        || die_with_reason "port_in_use" "port $FLAPJACK_PORT is already in use (needed for flapjack)"
    rm -rf "$FLAPJACK_DATA_DIR"
    mkdir -p "$FLAPJACK_DATA_DIR"
    log "Starting flapjack on port $FLAPJACK_PORT..."
    FLAPJACK_PORT="$FLAPJACK_PORT" \
        FLAPJACK_ADMIN_KEY="$INTEGRATION_FLAPJACK_ADMIN_KEY" \
        nohup "$FLAPJACK_BIN" \
        --port "$FLAPJACK_PORT" \
        --data-dir "$FLAPJACK_DATA_DIR" \
        > "$FLAPJACK_LOG" 2>&1 &
    echo $! > "$FLAPJACK_PID"
    wait_for_health "http://localhost:${FLAPJACK_PORT}/health" "flapjack" "${INTEGRATION_HEALTH_TIMEOUT:-15}" \
        || die_with_reason "health_check_timeout" "flapjack failed health check"
else
    log "WARNING: flapjack binary not found — skipping flapjack startup"
    log "  Set FLAPJACK_DEV_DIR to point to the flapjack_dev repo"
fi

# Start fjcloud API
log "Starting fjcloud API on port $API_PORT..."
INTEGRATION_SES_FROM_ADDRESS="$(env_or_repo_value SES_FROM_ADDRESS "integration@example.com")"
INTEGRATION_SES_REGION="$(env_or_repo_value SES_REGION "us-east-1")"
INTEGRATION_STORAGE_ENCRYPTION_KEY="$(env_or_repo_value STORAGE_ENCRYPTION_KEY "$(generate_hex_secret 32)")"
INTEGRATION_NODE_SECRET_BACKEND="$(env_or_repo_value NODE_SECRET_BACKEND "memory")"
INTEGRATION_JWT_SECRET="${JWT_SECRET:-$(generate_hex_secret 32)}"
INTEGRATION_API_ADMIN_KEY="${ADMIN_KEY:-$(generate_hex_secret 24)}"
DATABASE_URL="$INTEGRATION_RUNTIME_DB_URL" \
    LISTEN_ADDR="127.0.0.1:${API_PORT}" \
    S3_LISTEN_ADDR="127.0.0.1:${INTEGRATION_S3_PORT}" \
    JWT_SECRET="$INTEGRATION_JWT_SECRET" \
    ADMIN_KEY="$INTEGRATION_API_ADMIN_KEY" \
    RUST_LOG="info,api=debug" \
    SES_FROM_ADDRESS="$INTEGRATION_SES_FROM_ADDRESS" \
    SES_REGION="$INTEGRATION_SES_REGION" \
    STORAGE_ENCRYPTION_KEY="$INTEGRATION_STORAGE_ENCRYPTION_KEY" \
    NODE_SECRET_BACKEND="$INTEGRATION_NODE_SECRET_BACKEND" \
    FLAPJACK_ADMIN_KEY="$INTEGRATION_FLAPJACK_ADMIN_KEY" \
    LOCAL_DEV_FLAPJACK_URL="http://127.0.0.1:${FLAPJACK_PORT}" \
    nohup "$API_BIN" > "$API_LOG" 2>&1 &
echo $! > "$API_PID"

wait_for_health "http://localhost:${API_PORT}/health" "fjcloud API" "${INTEGRATION_HEALTH_TIMEOUT:-15}" \
    || die_with_reason "health_check_timeout" "fjcloud API failed health check"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "Integration stack is up!"
log "  API:       http://localhost:${API_PORT}"
if [ -n "$FLAPJACK_BIN" ] && [ -x "$FLAPJACK_BIN" ]; then
    log "  Flapjack:  http://localhost:${FLAPJACK_PORT}"
fi
log "  Database:      $(redact_db_url "$INTEGRATION_RUNTIME_DB_URL")"
log "  PIDs:          $PID_DIR"
log "  Flapjack admin: $(redact_secret "${INTEGRATION_FLAPJACK_ADMIN_KEY:-}")"
log "  Node secret:   ${INTEGRATION_NODE_SECRET_BACKEND}"
log "  Flapjack URL:  http://127.0.0.1:${FLAPJACK_PORT}"
