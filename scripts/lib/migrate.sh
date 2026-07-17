#!/usr/bin/env bash
# Shared migration helper — applies SQL migrations from a directory.
#
# Tracks applied migrations in a _schema_migrations table so reruns
# against an existing database skip already-applied files.
#
# Requires the caller to define: log()
# Returns non-zero on failure so callers control their own error handling.
#
# Usage: run_migrations <db_url> <migrations_dir>

run_migrations() {
    local db_url="$1"
    local migrations_dir="$2"

    run_migrations_with_runner "$migrations_dir" "$migrations_dir" \
        psql "$db_url"
}

# Escape a shell string for use inside a single-quoted PostgreSQL string literal.
sql_escape_literal() {
    local value="${1:-}"
    printf '%s' "$value" | sed "s/'/''/g"
}

run_migrations_with_runner() {
    local source_migrations_dir="$1"
    local runner_migrations_dir="$2"
    shift 2
    local runner_cmd=("$@")
    local migrations=("$source_migrations_dir"/*.sql)

    if [ "${#runner_cmd[@]}" -eq 0 ]; then
        log "No migration runner command provided"
        return 1
    fi

    if [ ! -e "${migrations[0]}" ]; then
        log "No SQL migration files found in: $source_migrations_dir"
        return 1
    fi

    # Ensure tracking table exists (idempotent).
    if ! "${runner_cmd[@]}" -c \
        "CREATE TABLE IF NOT EXISTS _schema_migrations (filename TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())" \
        -v ON_ERROR_STOP=1 >/dev/null; then
        log "Failed to create migration tracking table"
        return 1
    fi

    # Bootstrap: if tracking is empty but the database already has user tables,
    # this is a pre-tracking volume — seed all migration filenames so they're
    # skipped. (Adding a new migration to a legacy volume requires --clean.)
    local tracking_count
    tracking_count=$("${runner_cmd[@]}" -tAc \
        "SELECT count(*) FROM _schema_migrations" 2>/dev/null || echo "-1")

    if [ "$tracking_count" = "0" ]; then
        local has_user_tables
        has_user_tables=$("${runner_cmd[@]}" -tAc \
            "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name != '_schema_migrations' LIMIT 1" \
            2>/dev/null || true)

        if [ "$has_user_tables" = "1" ]; then
            log "Pre-tracking database detected — seeding migration history"
            for migration in "${migrations[@]}"; do
                local seed_name seed_name_sql
                seed_name="$(basename "$migration")"
                seed_name_sql="$(sql_escape_literal "$seed_name")"
                "${runner_cmd[@]}" -c \
                    "INSERT INTO _schema_migrations (filename) VALUES ('$seed_name_sql') ON CONFLICT DO NOTHING" \
                    -v ON_ERROR_STOP=1 >/dev/null 2>&1 || true
            done
        fi
    fi

    local applied=0
    local skipped=0

    for migration in "${migrations[@]}"; do
        local filename filename_sql
        filename="$(basename "$migration")"
        filename_sql="$(sql_escape_literal "$filename")"

        # Check if this migration was already applied.
        local already_applied
        already_applied=$("${runner_cmd[@]}" -tAc \
            "SELECT 1 FROM _schema_migrations WHERE filename='$filename_sql'" 2>/dev/null || true)

        if [ "$already_applied" = "1" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        local runner_migration="$runner_migrations_dir/$filename"
        log "Applying: $filename"
        if ! "${runner_cmd[@]}" -f "$runner_migration" -v ON_ERROR_STOP=1 >/dev/null; then
            log "Failed: $filename"
            return 1
        fi

        # Record successful application.
        if ! "${runner_cmd[@]}" -c \
            "INSERT INTO _schema_migrations (filename) VALUES ('$filename_sql')" \
            -v ON_ERROR_STOP=1 >/dev/null; then
            log "Failed to record migration: $filename"
            return 1
        fi
        applied=$((applied + 1))
    done

    if [ "$skipped" -gt 0 ]; then
        log "$skipped already-applied migrations skipped"
    fi
    log "All migrations applied ($applied new, $skipped skipped)"
}

run_docker_postgres_migrations() {
    local repo_root="$1"
    local source_migrations_dir="$2"
    local runner_migrations_dir="$3"
    local db_user="$4"
    local db_password="$5"
    local db_name="$6"

    (
        cd "$repo_root" || exit 1
        run_migrations_with_runner "$source_migrations_dir" "$runner_migrations_dir" \
            docker compose exec -T postgres \
                env "PGPASSWORD=$db_password" \
                psql -h 127.0.0.1 -U "$db_user" -d "$db_name"
    )
}
