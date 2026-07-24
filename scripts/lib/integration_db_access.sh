#!/usr/bin/env bash

INTEGRATION_DB_ACCESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION_DB_ACCESS_REPO_ROOT="$(cd "$INTEGRATION_DB_ACCESS_LIB_DIR/../.." && pwd)"

# shellcheck source=lib/db_url.sh
source "$INTEGRATION_DB_ACCESS_LIB_DIR/db_url.sh"
# shellcheck source=lib/env.sh
source "$INTEGRATION_DB_ACCESS_LIB_DIR/env.sh"

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

    read_env_assignment "$INTEGRATION_DB_ACCESS_REPO_ROOT/.env.local" DATABASE_URL
}

init_integration_db_access() {
    INTEGRATION_DB_ACCESS_MODE=""
    INTEGRATION_DB_ACCESS_FAILURE_HINT=""
    INTEGRATION_DOCKER_DB_USER=""
    INTEGRATION_DOCKER_DB_PASSWORD=""
    INTEGRATION_RUNTIME_DB_URL="${INTEGRATION_DB_URL:-}"

    if command -v psql >/dev/null 2>&1; then
        INTEGRATION_DB_ACCESS_MODE="host-psql"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    if ! (cd "$INTEGRATION_DB_ACCESS_REPO_ROOT" && docker compose ps --status running postgres >/dev/null 2>&1); then
        return 1
    fi

    local source_db_url
    source_db_url="$(resolve_local_dev_database_url)" || {
        INTEGRATION_DB_ACCESS_FAILURE_HINT="Docker Compose Postgres is running but DATABASE_URL is not set in env or .env.local - set DATABASE_URL in .env.local for docker fallback access"
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
                cd "$INTEGRATION_DB_ACCESS_REPO_ROOT" || exit 1
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
