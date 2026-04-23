#!/usr/bin/env bash
# integration-down.sh — Tear down the integration test stack.
#
# Kills API + flapjack processes, drops test DB, cleans up PID files.
# Idempotent: safe to run even when nothing is running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/integration_stack_env.sh
source "$SCRIPT_DIR/lib/integration_stack_env.sh"

INTEGRATION_DB="${INTEGRATION_DB:-fjcloud_integration_test}"
INTEGRATION_DB_USER="${INTEGRATION_DB_USER:-$(whoami)}"
INTEGRATION_DB_HOST="${INTEGRATION_DB_HOST:-localhost}"
INTEGRATION_DB_PORT="${INTEGRATION_DB_PORT:-5432}"

read_env_assignment() {
    local env_file="$1"
    local target_key="$2"

    [ -f "$env_file" ] || return 1

    local line key value quote_char
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"

        if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        if ! [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            continue
        fi

        key="${BASH_REMATCH[2]}"
        [ "$key" = "$target_key" ] || continue

        value="${BASH_REMATCH[3]}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        if [ -n "$value" ]; then
            quote_char="${value:0:1}"
            if { [ "$quote_char" = "'" ] || [ "$quote_char" = '"' ]; } && [ "${value: -1}" = "$quote_char" ]; then
                value="${value:1:${#value}-2}"
            fi
        fi

        printf '%s\n' "$value"
        return 0
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

init_integration_db_access() {
    INTEGRATION_DB_ACCESS_MODE=""
    INTEGRATION_DOCKER_DB_USER=""
    INTEGRATION_DOCKER_DB_PASSWORD=""

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

    local source_db_url
    source_db_url="$(resolve_local_dev_database_url)" || return 1

    INTEGRATION_DOCKER_DB_USER="$(db_url_user "$source_db_url")" || return 1
    INTEGRATION_DOCKER_DB_PASSWORD="$(db_url_password "$source_db_url")" || return 1
    INTEGRATION_DB_ACCESS_MODE="docker-compose-psql"
    return 0
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
            return 1
            ;;
    esac
}

# Validate DB name to prevent SQL injection (same check as integration-up.sh)
db_name_valid=true
if ! validate_integration_db_name "$INTEGRATION_DB"; then
    db_name_valid=false
fi

PID_DIR="$REPO_ROOT/.integration"
FLAPJACK_PID="$PID_DIR/flapjack.pid"
API_PID="$PID_DIR/api.pid"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[integration-down] $*"; }

# shellcheck source=lib/process.sh
source "$SCRIPT_DIR/lib/process.sh"

# ---------------------------------------------------------------------------
# 1. Stop processes
# ---------------------------------------------------------------------------
kill_pid_file "$API_PID" "fjcloud API" "api"
kill_pid_file "$FLAPJACK_PID" "flapjack" "flapjack"

# ---------------------------------------------------------------------------
# 2. Drop test database
# ---------------------------------------------------------------------------
if [ "$db_name_valid" != true ]; then
    log "ERROR: INTEGRATION_DB must be a safe PostgreSQL identifier: '$INTEGRATION_DB' (skipping database drop)"
elif ! init_integration_db_access; then
    log "psql or docker compose postgres fallback not available — skipping database drop"
elif db_exists_result="$(
    run_integration_psql postgres \
        -tc "SELECT 1 FROM pg_database WHERE datname = '$INTEGRATION_DB'" 2>/dev/null
)"; then
    if echo "$db_exists_result" | grep -q 1; then
            log "Dropping database: $INTEGRATION_DB"
            # Terminate any remaining connections
            run_integration_psql postgres \
                -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$INTEGRATION_DB' AND pid <> pg_backend_pid();" \
                >/dev/null 2>&1 || true
            run_integration_psql postgres \
                -c "DROP DATABASE IF EXISTS \"$INTEGRATION_DB\"" \
                >/dev/null 2>&1 || true
            log "Database dropped"
    else
            log "Database $INTEGRATION_DB does not exist (nothing to drop)"
    fi
else
    log "Unable to query postgres for database '$INTEGRATION_DB' — skipping database drop"
fi

# ---------------------------------------------------------------------------
# 3. Clean up
# ---------------------------------------------------------------------------
rm -f "$PID_DIR"/*.log 2>/dev/null || true
rm -rf "$PID_DIR/flapjack-data" 2>/dev/null || true
if [ -d "$PID_DIR" ]; then
    rmdir "$PID_DIR" 2>/dev/null || true
fi

log "Integration stack torn down"
