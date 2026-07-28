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

SCHEMA_DRIFT_PROBE_SCRIPT="${FJCLOUD_TEST_SCHEMA_DRIFT_PROBE_SCRIPT:-$SCRIPT_DIR/probe_local_schema_drift.sh}"

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

write_docker_psql_wrapper() {
    local wrapper_path="$1"

    cat > "$wrapper_path" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/db_url.sh
source "$FJCLOUD_DB_URL_LIB"

database_url="${1:-}"
[ -n "$database_url" ] || {
    echo "psql wrapper requires DATABASE_URL argument" >&2
    exit 1
}
shift

db_user="$(require_db_url_part "$database_url" db_url_user)"
db_password="$(require_db_url_part "$database_url" db_url_password)"
db_name="$(require_db_url_part "$database_url" db_url_database)"

translated_args=()
previous_arg=""
for arg in "$@"; do
    if [ "$previous_arg" = "-f" ]; then
        case "$arg" in
            "$FJCLOUD_HOST_MIGRATIONS_DIR"/*)
                arg="$FJCLOUD_DOCKER_MIGRATIONS_DIR/$(basename "$arg")"
                ;;
        esac
    fi
    translated_args+=("$arg")
    previous_arg="$arg"
done

cd "$FJCLOUD_REPO_ROOT"
exec docker compose exec -T postgres \
    env "PGPASSWORD=$db_password" \
    psql -h 127.0.0.1 -U "$db_user" -d "$db_name" \
    "${translated_args[@]}"
WRAPPER
    chmod +x "$wrapper_path"
}

run_schema_drift_probe_with_docker_psql() {
    local wrapper_dir wrapper_rc

    wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/fjcloud_probe_psql.XXXXXX")"
    write_docker_psql_wrapper "$wrapper_dir/psql"

    FJCLOUD_DB_URL_LIB="$SCRIPT_DIR/lib/db_url.sh" \
    FJCLOUD_REPO_ROOT="$REPO_ROOT" \
    FJCLOUD_HOST_MIGRATIONS_DIR="$REPO_ROOT/infra/migrations" \
    FJCLOUD_DOCKER_MIGRATIONS_DIR="/migrations" \
    PATH="$wrapper_dir:$PATH" \
        bash "$SCHEMA_DRIFT_PROBE_SCRIPT" || wrapper_rc=$?
    wrapper_rc="${wrapper_rc:-0}"

    rm -rf "$wrapper_dir"
    return "$wrapper_rc"
}

run_schema_drift_probe() {
    if command -v psql >/dev/null 2>&1; then
        bash "$SCHEMA_DRIFT_PROBE_SCRIPT"
    else
        run_schema_drift_probe_with_docker_psql
    fi
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

run_schema_drift_probe \
    || die "schema drift probe failed"

log "Done"
