#!/usr/bin/env bash
# local-dev-migrate.sh — Apply database migrations for local development.
#
# Prerequisites: source .env.local first to set DATABASE_URL.
# Not safely rerunnable — migrations are not uniformly idempotent.
# To reset, drop the database and re-create it before running again.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/migrate.sh
source "$SCRIPT_DIR/lib/migrate.sh"
# shellcheck source=lib/db_url.sh
source "$SCRIPT_DIR/lib/db_url.sh"

log() { echo "[local-dev-migrate] $*"; }
die() {
    echo "[local-dev-migrate] ERROR: $*" >&2
    exit 1
}

require_database_url_part() {
    local extractor="$1"
    local error_message="$2"
    local value

    value="$(require_db_url_part "$DATABASE_URL" "$extractor")" || die "$error_message"
    printf '%s\n' "$value"
}

run_local_docker_fallback_migrations() {
    local db_user db_password db_name

    db_user="$(require_database_url_part db_url_user "DATABASE_URL must include a username")"
    db_password="$(require_database_url_part db_url_password "DATABASE_URL must include a password")"
    db_name="$(require_database_url_part db_url_database "DATABASE_URL must include a database name")"
    require_database_url_part db_url_host "DATABASE_URL must include a hostname" >/dev/null
    require_database_url_part db_url_port "DATABASE_URL must include a valid port" >/dev/null

    command -v docker >/dev/null 2>&1 \
        || die "psql is unavailable on host and docker compose postgres fallback is unavailable; install psql or install/start docker compose postgres"

    run_docker_postgres_migrations \
        "$REPO_ROOT" \
        "$REPO_ROOT/infra/migrations" \
        "/migrations" \
        "$db_user" \
        "$db_password" \
        "$db_name" \
        || die "psql is unavailable on host and docker compose postgres fallback failed; install psql or install/start docker compose postgres"
}

[ -n "${DATABASE_URL:-}" ] || {
    die "DATABASE_URL is not set. Run: source .env.local"
}

log "Applying migrations to: $(redact_db_url "$DATABASE_URL")"

if command -v psql >/dev/null 2>&1; then
    run_migrations "$DATABASE_URL" "$REPO_ROOT/infra/migrations" \
        || die "migrations failed"
else
    run_local_docker_fallback_migrations
fi

log "Done"
