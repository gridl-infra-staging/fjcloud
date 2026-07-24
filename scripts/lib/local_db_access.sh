#!/usr/bin/env bash
# Shared local Postgres access helpers for sourceable local-dev scripts.

LOCAL_DB_ACCESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DB_ACCESS_REPO_ROOT="${REPO_ROOT:-$(cd "$LOCAL_DB_ACCESS_LIB_DIR/../.." && pwd)}"

# shellcheck source=db_url.sh
source "$LOCAL_DB_ACCESS_LIB_DIR/db_url.sh"

local_db_access_log() {
    if declare -F log >/dev/null 2>&1; then
        log "$*"
    else
        echo "$*"
    fi
}

local_db_access_die() {
    if declare -F die >/dev/null 2>&1; then
        die "$*"
    else
        echo "ERROR: $*" >&2
        exit 1
    fi
}

require_local_database_access() {
    local skip_context="$1"

    if [ -z "${DATABASE_URL:-}" ]; then
        local_db_access_log "WARNING: DATABASE_URL is not set — skipping ${skip_context}"
        return 1
    fi

    if command -v psql >/dev/null 2>&1; then
        DB_ACCESS_MODE="host-psql"
        return 0
    fi

    if command -v docker >/dev/null 2>&1 \
        && (cd "$LOCAL_DB_ACCESS_REPO_ROOT" && docker compose ps --status running postgres >/dev/null 2>&1); then
        DB_ACCESS_MODE="docker-compose-psql"
        return 0
    fi

    local_db_access_log "WARNING: psql not found and Docker Postgres is unavailable — skipping ${skip_context}"
    return 1
}

run_local_psql() {
    local db_user db_password db_name

    case "${DB_ACCESS_MODE:-}" in
        host-psql)
            PSQLRC=/dev/null psql "$DATABASE_URL" "$@"
            ;;
        docker-compose-psql)
            db_user="$(db_url_user "$DATABASE_URL")" \
                || local_db_access_die "DATABASE_URL must include a username for docker compose psql access"
            db_password="$(db_url_password "$DATABASE_URL")" \
                || local_db_access_die "DATABASE_URL must include a password for docker compose psql access"
            db_name="$(db_url_database "$DATABASE_URL")" \
                || local_db_access_die "DATABASE_URL must include a database name for docker compose psql access"

            (
                cd "$LOCAL_DB_ACCESS_REPO_ROOT" || exit 1
                PSQLRC=/dev/null docker compose exec -T postgres \
                    env "PGPASSWORD=$db_password" \
                    psql -h 127.0.0.1 -U "$db_user" -d "$db_name" "$@"
            )
            ;;
        *)
            local_db_access_die "Database access requested before require_local_database_access initialized DB_ACCESS_MODE"
            ;;
    esac
}
