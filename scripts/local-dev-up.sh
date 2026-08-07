#!/usr/bin/env bash
# local-dev-up.sh — Start the local development environment.
#
# Starts Docker Compose Postgres, runs migrations, starts Flapjack,
# and prints instructions for starting the API and web processes manually.
#
# Prerequisites: docker, curl, .env.local at repo root.
# Optional: FLAPJACK_DEV_DIR pointing to flapjack_dev repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

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
# shellcheck source=lib/local_stack_contract.sh
source "$SCRIPT_DIR/lib/local_stack_contract.sh"
# shellcheck source=lib/compose_project.sh
source "$SCRIPT_DIR/lib/compose_project.sh"
# shellcheck source=lib/docker.sh
source "$SCRIPT_DIR/lib/docker.sh"
# shellcheck source=lib/local_source_providers.sh
source "$SCRIPT_DIR/lib/local_source_providers.sh"
# shellcheck source=lib/playwright_port_plan.sh
source "$SCRIPT_DIR/lib/playwright_port_plan.sh"

# Each worktree gets its own docker compose project namespace so a second
# worktree's `docker compose up` cannot clobber the first worktree's
# containers (and its postgres volume). See scripts/lib/compose_project.sh
# for the resolution rules and operator override path.
export COMPOSE_PROJECT_NAME="$(resolve_compose_project_name "$REPO_ROOT")"

PID_DIR="$REPO_ROOT/.local"
FLAPJACK_PID="$PID_DIR/flapjack.pid"
FLAPJACK_LOG="$PID_DIR/flapjack.log"
FLAPJACK_DATA_DIR="${FLAPJACK_DATA_DIR:-$PID_DIR/flapjack-data}"

log() { echo "[local-dev-up] $*"; }
die() {
    echo "[local-dev-up] ERROR: $*" >&2
    exit 1
}

# Fail fast when two services this run would start are configured onto one host
# port. Without this the collision surfaces late and misleadingly: whichever
# service binds first wins, and the second one's own check_port_available
# reports a bare "port N is already in use" that never names the override that
# took it. An operator reading that diagnostic cannot tell a co-resident
# worktree's stack from their own misconfiguration, which is the difference
# between "wait" and "edit one variable".
#
# Takes LABEL=PORT pairs. Empty ports are skipped so callers can pass
# conditionally-started services without branching at the call site.
assert_no_host_port_collisions() {
    local pair label port seen_label
    local -a seen_labels=() seen_ports=()
    local i

    for pair in "$@"; do
        label="${pair%%=*}"
        port="${pair#*=}"
        [ -n "$port" ] || continue

        i=0
        while [ "$i" -lt "${#seen_ports[@]}" ]; do
            if [ "${seen_ports[$i]}" = "$port" ]; then
                seen_label="${seen_labels[$i]}"
                die "host port $port is claimed by both $seen_label and $label; point one of them at a free port (for example $label=$((port + 10))) so both services can run at once"
            fi
            i=$((i + 1))
        done

        seen_labels+=("$label")
        seen_ports+=("$port")
    done
}

# Collect the flapjack ports this run would bind, as LABEL=PORT pairs, so the
# collision guard sees multi-region layouts and not just the single default.
flapjack_configured_port_pairs() {
    local region_port region port
    if [ "${FLAPJACK_SINGLE_INSTANCE:-}" = "1" ] || [ -z "${FLAPJACK_REGIONS:-}" ]; then
        printf 'FLAPJACK_PORT=%s\n' "$FLAPJACK_PORT"
        return
    fi
    for region_port in $FLAPJACK_REGIONS; do
        region="${region_port%%:*}"
        port="${region_port##*:}"
        printf 'FLAPJACK_REGIONS[%s]=%s\n' "$region" "$port"
    done
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

cargo_env_toml_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

write_platform_test_cargo_env_config() {
    local source_base_url="$1"
    local config_dir="$REPO_ROOT/infra/.cargo"
    local config_path="$config_dir/config.toml"
    local source_base_url_toml admin_key_toml tmp

    if [ -f "$config_path" ] \
        && ! grep -Fqx "$LOCAL_DEV_PLATFORM_TEST_CARGO_ENV_MARKER" "$config_path"
    then
        log "WARNING: $config_path exists and is not local-dev-up generated; not overwriting standalone cargo env"
        return 0
    fi

    mkdir -p "$config_dir"
    source_base_url_toml="$(cargo_env_toml_escape "$source_base_url")"
    admin_key_toml="$(cargo_env_toml_escape "$FLAPJACK_ADMIN_KEY")"
    tmp="$(mktemp "$config_dir/config.toml.XXXXXX")"
    {
        printf '%s\n' "$LOCAL_DEV_PLATFORM_TEST_CARGO_ENV_MARKER"
        printf '%s\n' '# Cargo reads this when invoked from infra/; keep runtime ownership in local-dev-up.sh.'
        printf '%s\n' '[env]'
        printf 'FJCLOUD_ALGOLIA_SOURCE_BASE_URL = "%s"\n' "$source_base_url_toml"
        printf 'FLAPJACK_ADMIN_KEY = "%s"\n' "$admin_key_toml"
    } > "$tmp"
    mv "$tmp" "$config_path"
}

prepare_flapjack_auth_state() {
    local data_dir="$1"
    local admin_key_file="$data_dir/.admin_key"
    local tmp

    mkdir -p "$data_dir"
    # Flapjack rotates the admin entry from this launch value while preserving
    # non-admin API-key hashes and encrypted key material in the owned data dir.
    tmp="$(mktemp "$data_dir/.admin_key.XXXXXX")"
    printf '%s\n' "$FLAPJACK_ADMIN_KEY" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$admin_key_file"
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

# Reads docker compose's reported Health state for the named service.
# The seaweedfs image ships with its own curl-based healthcheck (accepts
# HTTP 200 or 403 — 403 is the correct unauthenticated S3 response) which
# IS the single source of truth for "is seaweedfs up". The previous
# probe duplicated that check via an outside-the-container curl, but
# routinely fired before the container had finished booting — leading
# to a permanent false-negative "[local-dev-up] seaweedfs failed health
# check after 15s" on every cold start. Anchored 2026-05-31.
compose_service_health() {
    local service="$1"
    (cd "$REPO_ROOT" && docker compose ps "$service" --format json 2>/dev/null) \
        | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(0)
items = payload if isinstance(payload, list) else [payload]
for item in items:
    h = item.get("Health") or ""
    if h:
        print(h)
        break
' 2>/dev/null || true
}

seaweedfs_is_healthy() {
    [ "$(compose_service_health seaweedfs)" = "healthy" ]
}

start_seaweedfs_service() {
    local port="$1" timeout="${2:-60}"
    log "Starting seaweedfs..."
    (cd "$REPO_ROOT" && docker compose up -d seaweedfs) 2>&1 | while IFS= read -r line; do log "$line"; done
    # Cold-boot of seaweedfs (image pull + start) can exceed 15s; default
    # to 60s so the first run on a fresh machine doesn't false-negative.
    if wait_until_success "$timeout" 2 seaweedfs_is_healthy; then
        log "seaweedfs is healthy (per docker compose health)"
        return 0
    fi
    log "seaweedfs failed health check after ${timeout}s (docker compose Health was not 'healthy') — non-fatal; API will fall back to InMemoryObjectStore"
    return 1
}

source_provider_is_healthy() {
    local service="$1" health_url="$2"
    [ "$(compose_service_health "$service")" = "healthy" ] \
        && curl -fsS -o /dev/null "$health_url"
}

start_source_provider_services() {
    local meili_port="$1" typesense_port="$2" timeout="${3:-60}"
    local meili_url="http://127.0.0.1:${meili_port}"
    local typesense_url="http://127.0.0.1:${typesense_port}"

    source_provider_prepare_run "$REPO_ROOT" || return 1
    source_provider_mark_stack_owned
    log "Starting Meilisearch and Typesense source providers..."
    (cd "$REPO_ROOT" && docker compose up -d meilisearch typesense) 2>&1 \
        | while IFS= read -r line; do log "$line"; done \
        || return 1

    if ! wait_until_success "$timeout" 2 \
        source_provider_is_healthy meilisearch "$meili_url/health"
    then
        return 1
    fi
    if ! wait_until_success "$timeout" 2 \
        source_provider_is_healthy typesense "$typesense_url/health"
    then
        return 1
    fi

    source_provider_seed_and_capture "$meili_url" "$typesense_url"
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

database_url_host_is_loopback() {
    local host="$1"

    case "$host" in
        localhost|127.0.0.1|::1|'[::1]')
            return 0
            ;;
        *)
            return 1
            ;;
    esac
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
require_docker_daemon
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

DB_HOST="$(require_database_url_part db_url_host "DATABASE_URL must include a hostname")"
database_url_host_is_loopback "$DB_HOST" \
    || die "DATABASE_URL host must be loopback for local-dev-up (got ${DB_HOST})"
require_database_url_part db_url_port "DATABASE_URL must include a valid port" >/dev/null

playwright_apply_manual_stack_port_defaults "$SCRIPT_DIR/.." "$REPO_ROOT" \
    || die "failed to derive the manual-stack port plan from web/playwright.config.contract.ts"

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

# Run before local-dev-down.sh and before any container or process starts, so a
# misconfigured run costs a diagnostic rather than a half-started stack the
# operator then has to tear down by hand. Source-provider ports are included
# only when their compose profile is on, because that is the only case in which
# this script binds them.
declare -a HOST_PORT_PAIRS=()
while IFS= read -r flapjack_pair; do
    [ -n "$flapjack_pair" ] && HOST_PORT_PAIRS+=("$flapjack_pair")
done <<EOF_FLAPJACK_PORTS
$(flapjack_configured_port_pairs)
EOF_FLAPJACK_PORTS
HOST_PORT_PAIRS+=(
    "LOCAL_DB_PORT=$DB_PORT"
    "LOCAL_S3_PORT=$LOCAL_S3_PORT"
    "LOCAL_MAILPIT_UI_PORT=$LOCAL_MAILPIT_UI_PORT"
    "LOCAL_SMTP_PORT=$LOCAL_SMTP_PORT"
)
if source_provider_profile_enabled; then
    HOST_PORT_PAIRS+=(
        "LOCAL_MEILISEARCH_PORT=$LOCAL_MEILISEARCH_PORT"
        "LOCAL_TYPESENSE_PORT=$LOCAL_TYPESENSE_PORT"
    )
fi
assert_no_host_port_collisions "${HOST_PORT_PAIRS[@]}"

# ---------------------------------------------------------------------------
# 2. Clean stale state
# ---------------------------------------------------------------------------
"$SCRIPT_DIR/local-dev-down.sh" 2>/dev/null || true
mkdir -p "$PID_DIR"

# ---------------------------------------------------------------------------
# 3. Start Postgres via Docker Compose
# ---------------------------------------------------------------------------
# Step 2 stopped this stack's own Postgres, so a listener still holding the
# DATABASE_URL port is a foreign server. Without this check compose leaves the
# port to that server and every later probe — readiness, migrations, row counts
# — reports healthy against a database fjcloud does not own.
check_port_available "$DB_PORT" "postgres from DATABASE_URL" \
    || die "port $DB_PORT is already in use (needed for postgres from DATABASE_URL); free it or point DATABASE_URL at an unused port so local queries cannot reach a foreign database"
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
SOURCE_PROVIDERS_HEALTHY=0

local_s3_port="$LOCAL_S3_PORT"
if start_seaweedfs_service "$local_s3_port" 15; then
    SEAWEEDFS_HEALTHY=1
    # SeaweedFS now runs with a deterministic local S3 identity. Bucket creation
    # is delegated to the signed Rust cold-storage proof instead of an unsigned
    # bootstrap curl, so real AWS credentials cannot accidentally affect local S3.
    log "S3 endpoint reachable at http://localhost:${local_s3_port}"
fi

if start_optional_service "mailpit" "http://localhost:${LOCAL_MAILPIT_UI_PORT}/api/v1/info" 15; then
    MAILPIT_HEALTHY=1
fi

if source_provider_profile_enabled; then
    # Resolved and collision-checked at the top of this script; do not
    # re-default here or the guard and the bind would disagree.
    local_meilisearch_port="$LOCAL_MEILISEARCH_PORT"
    local_typesense_port="$LOCAL_TYPESENSE_PORT"
    if start_source_provider_services \
        "$local_meilisearch_port" \
        "$local_typesense_port" \
        "${SOURCE_PROVIDER_HEALTH_TIMEOUT_SECONDS:-60}"
    then
        SOURCE_PROVIDERS_HEALTHY=1
    else
        log "source providers failed health checks or fixture seeding — non-fatal; source migration fixtures are unavailable"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Run migrations
# ---------------------------------------------------------------------------
log "Applying migrations to: $(redact_db_url "$DATABASE_URL")"
HOST_MIGRATIONS_DIR="${FJCLOUD_HOST_MIGRATIONS_DIR:-$REPO_ROOT/infra/migrations}"
CONTAINER_MIGRATIONS_DIR="${FJCLOUD_DOCKER_MIGRATIONS_DIR:-/migrations}"
run_container_migrations "$HOST_MIGRATIONS_DIR" "$CONTAINER_MIGRATIONS_DIR" \
    || die "migrations failed"

# ---------------------------------------------------------------------------
# 5. Start Flapjack (if available)
# ---------------------------------------------------------------------------
# Multi-region mode: FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701 eu-central-1:7702"
# Single-instance mode (default): FLAPJACK_SINGLE_INSTANCE=1 or FLAPJACK_REGIONS unset
FLAPJACK_BIN=""
FLAPJACK_RESOLUTION_STATUS=0
FLAPJACK_BIN="$(find_flapjack_binary "$FLAPJACK_DEV_DIR")" || FLAPJACK_RESOLUTION_STATUS=$?
if [ "$FLAPJACK_RESOLUTION_STATUS" -eq "$FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS" ]; then
    die "selected FLAPJACK_DEV_DIR source build or provenance validation failed: $FLAPJACK_DEV_DIR"
fi
FLAPJACK_BIN_PROVENANCE="$(flapjack_source_provenance_summary)"
if [ -n "$FLAPJACK_BIN" ] && [ -x "$FLAPJACK_BIN" ]; then
    flapjack_export_required_artifact_identity "$FLAPJACK_BIN" \
        || die "failed to derive required Flapjack artifact identity from selected binary: $FLAPJACK_BIN"
fi

# Helper to start one Flapjack instance with the given region, port, and data dir.
start_one_flapjack() {
    local region="$1" port="$2" data_dir="$3"
    local pid_file="$PID_DIR/flapjack-${region}.pid"
    local log_file="$PID_DIR/flapjack-${region}.log"

    check_port_available "$port" "flapjack-${region}" \
        || die "port $port is already in use (needed for flapjack-${region})"

    log "Starting flapjack (${region}) on port ${port}..."
    prepare_flapjack_auth_state "$data_dir"

    FLAPJACK_ADMIN_KEY="$FLAPJACK_ADMIN_KEY" \
        nohup "$FLAPJACK_BIN" \
            --port "$port" \
            --data-dir "$data_dir" \
            < /dev/null > "$log_file" 2>&1 &
    echo $! > "$pid_file"

    wait_for_health "http://127.0.0.1:${port}/health" "flapjack-${region}" 15 \
        || die "flapjack-${region} did not become healthy"

    local identity_reason
    identity_reason="$(flapjack_runtime_identity_reason "http://127.0.0.1:${port}")"
    if [ "$identity_reason" != "match" ]; then
        die "flapjack-${region} $(flapjack_identity_rejection_message \
            "$identity_reason" "http://127.0.0.1:${port}" "$FLAPJACK_BIN")"
    fi
}

FLAPJACK_STARTED_REGIONS=""
PLATFORM_TEST_ALGOLIA_SOURCE_BASE_URL=""

if [ -n "$FLAPJACK_BIN" ] && [ -x "$FLAPJACK_BIN" ]; then
    log "Flapjack binary: $FLAPJACK_BIN"
    log "Flapjack provenance: $FLAPJACK_BIN_PROVENANCE"
    if [ "${FLAPJACK_SINGLE_INSTANCE:-}" = "1" ] || [ -z "${FLAPJACK_REGIONS:-}" ]; then
        # Single-instance mode (backward compatible).
        start_one_flapjack "default" "$FLAPJACK_PORT" "$FLAPJACK_DATA_DIR"
        # Symlink the default PID for backward compat with old local-dev-down.sh.
        ln -sf "flapjack-default.pid" "$FLAPJACK_PID"
        FLAPJACK_STARTED_REGIONS="default:${FLAPJACK_PORT}"
        PLATFORM_TEST_ALGOLIA_SOURCE_BASE_URL="http://127.0.0.1:${FLAPJACK_PORT}"
    else
        # Multi-region mode: start one Flapjack per region.
        for region_port in $FLAPJACK_REGIONS; do
            region="${region_port%%:*}"
            port="${region_port##*:}"
            data_dir="$PID_DIR/flapjack-data-${region}"
            start_one_flapjack "$region" "$port" "$data_dir"
            FLAPJACK_STARTED_REGIONS="${FLAPJACK_STARTED_REGIONS:+${FLAPJACK_STARTED_REGIONS} }${region}:${port}"
            if [ -z "$PLATFORM_TEST_ALGOLIA_SOURCE_BASE_URL" ]; then
                PLATFORM_TEST_ALGOLIA_SOURCE_BASE_URL="http://127.0.0.1:${port}"
            fi
        done
    fi
else
    log "WARNING: flapjack binary not found — skipping flapjack startup"
    log "  Set FLAPJACK_DEV_DIR to point to the flapjack_dev repo"
fi

if [ -n "$PLATFORM_TEST_ALGOLIA_SOURCE_BASE_URL" ]; then
    write_platform_test_cargo_env_config "$PLATFORM_TEST_ALGOLIA_SOURCE_BASE_URL"
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
        log "  Algolia source:  http://127.0.0.1:${port}"
    done
fi
# Show SeaweedFS/Mailpit only when health checks passed during startup.
if [ "$SEAWEEDFS_HEALTHY" = "1" ]; then
    log "  SeaweedFS S3:   http://localhost:${LOCAL_S3_PORT}"
fi
if [ "$MAILPIT_HEALTHY" = "1" ]; then
    log "  Mailpit UI:     http://localhost:${LOCAL_MAILPIT_UI_PORT}"
fi
if [ "$SOURCE_PROVIDERS_HEALTHY" = "1" ]; then
    log "  Meilisearch:    http://localhost:${LOCAL_MEILISEARCH_PORT}"
    log "  Typesense:      http://localhost:${LOCAL_TYPESENSE_PORT}"
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
