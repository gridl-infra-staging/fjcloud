#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib/db_url.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/db_url.sh"

build_integration_db_url() {
    if [ -n "${INTEGRATION_DB_URL:-}" ]; then
        printf '%s\n' "$INTEGRATION_DB_URL"
        return 0
    fi

    local host="${INTEGRATION_DB_HOST:-localhost}"
    local port="${INTEGRATION_DB_PORT:-5432}"
    local user="${INTEGRATION_DB_USER:-}"
    local password="${INTEGRATION_DB_PASSWORD:-}"
    local db="${INTEGRATION_DB:-fjcloud_integration_test}"

    if [ -n "$user" ] && [ -n "$password" ]; then
        printf 'postgres://%s:%s@%s:%s/%s\n' "$user" "$password" "$host" "$port" "$db"
    elif [ -n "$user" ]; then
        printf 'postgres://%s@%s:%s/%s\n' "$user" "$host" "$port" "$db"
    else
        printf 'postgres://%s:%s/%s\n' "$host" "$port" "$db"
    fi
}

sanitized_integration_db_url() {
    local url
    url="$(build_integration_db_url)"
    # Redact any embedded password regardless of whether INTEGRATION_DB_PASSWORD
    # matches — handles both built URLs and explicit INTEGRATION_DB_URL values.
    redact_db_url "$url"
}

init_integration_env_defaults() {
    export INTEGRATION_DB="${INTEGRATION_DB:-fjcloud_integration_test}"
    export INTEGRATION_DB_USER="${INTEGRATION_DB_USER:-$(whoami)}"
    export INTEGRATION_DB_HOST="${INTEGRATION_DB_HOST:-localhost}"
    export INTEGRATION_DB_PORT="${INTEGRATION_DB_PORT:-5432}"
    export INTEGRATION_DB_PASSWORD="${INTEGRATION_DB_PASSWORD:-}"
    export INTEGRATION_DB_URL="${INTEGRATION_DB_URL:-$(build_integration_db_url)}"

    if [ -n "$INTEGRATION_DB_PASSWORD" ] && [ -z "${PGPASSWORD:-}" ]; then
        export PGPASSWORD="$INTEGRATION_DB_PASSWORD"
    fi
}

validate_integration_db_name() {
    local db_name="${1:-}"
    [[ "$db_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}
