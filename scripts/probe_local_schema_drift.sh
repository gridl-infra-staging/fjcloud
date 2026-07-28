#!/usr/bin/env bash
# Compare the local database's public columns with a schema built from migrations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/db_url.sh
source "$SCRIPT_DIR/lib/db_url.sh"
# shellcheck source=lib/migrate.sh
source "$SCRIPT_DIR/lib/migrate.sh"

log() {
    printf '%s\n' "$*"
}

if [ -z "${DATABASE_URL:-}" ]; then
    log "DATABASE_URL is not set. Run: source .env.local"
    exit 1
fi

build_scratch_database_url() {
    local database_url="$1"
    local scratch_database="$2"
    local current_database url_without_query url_query=""

    current_database="$(require_db_url_part "$database_url" db_url_database)" || {
        log "DATABASE_URL must include a database name"
        return 1
    }
    url_without_query="${database_url%%\?*}"
    if [[ "$database_url" == *\?* ]]; then
        url_query="?${database_url#*\?}"
    fi

    printf '%s/%s%s\n' "${url_without_query%/"$current_database"}" "$scratch_database" "$url_query"
}

scratch_database_name="fjcloud_schema_oracle_$$_${RANDOM}"
scratch_database_created=0
comparison_dir=""

cleanup_scratch_database() {
    local pending_status=$?
    local cleanup_status=0

    if [ "$scratch_database_created" -eq 1 ]; then
        if ! psql "$DATABASE_URL" -c \
            "DROP DATABASE IF EXISTS \"$scratch_database_name\"" >/dev/null; then
            log "Failed to drop scratch schema oracle database"
            cleanup_status=1
        fi
        scratch_database_created=0
    fi

    if [ -n "$comparison_dir" ]; then
        rm -rf -- "$comparison_dir"
        comparison_dir=""
    fi

    if [ "$pending_status" -ne 0 ]; then
        return "$pending_status"
    fi
    if [ "$cleanup_status" -ne 0 ]; then
        trap - EXIT
        exit "$cleanup_status"
    fi
}

trap 'cleanup_scratch_database' EXIT
trap 'cleanup_scratch_database; exit 130' INT
trap 'cleanup_scratch_database; exit 143' TERM

scratch_database_url="$(build_scratch_database_url "$DATABASE_URL" "$scratch_database_name")" || exit 1

if ! psql "$DATABASE_URL" -c \
    "CREATE DATABASE \"$scratch_database_name\"" >/dev/null; then
    log "Failed to create scratch database for schema oracle"
    exit 1
fi
scratch_database_created=1

if ! run_migrations_with_runner \
    "$REPO_ROOT/infra/migrations" \
    "$REPO_ROOT/infra/migrations" \
    psql "$scratch_database_url"; then
    log "Failed to build scratch schema oracle from migrations"
    exit 1
fi

schema_columns_sql="
SELECT table_schema, table_name, column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name != '_schema_migrations'
ORDER BY table_name, column_name"

if ! oracle_columns="$(psql "$scratch_database_url" -tAc "$schema_columns_sql")"; then
    log "Failed to inspect scratch schema oracle"
    exit 1
fi
if ! target_columns="$(psql "$DATABASE_URL" -tAc "$schema_columns_sql")"; then
    log "Failed to inspect target schema"
    exit 1
fi

comparison_dir="$(mktemp -d "${TMPDIR:-/tmp}/fjcloud_schema_drift.XXXXXX")"
comparison_input="$comparison_dir/columns"
differences_file="$comparison_dir/differences"

printf '%s\n' "$oracle_columns" |
    awk -F'|' 'NF >= 3 { print "oracle|" $2 "|" $3 }' > "$comparison_input"
printf '%s\n' "$target_columns" |
    awk -F'|' 'NF >= 3 { print "target|" $2 "|" $3 }' >> "$comparison_input"

awk -F'|' '
    $1 == "oracle" {
        oracle_columns[$2 "." $3] = 1
        oracle_tables[$2] = 1
        next
    }
    $1 == "target" {
        target_columns[$2 "." $3] = 1
        target_column_tables[$2 "." $3] = $2
        target_tables[$2] = 1
    }
    END {
        for (column in oracle_columns) {
            if (!(column in target_columns)) {
                print column "|missing " column "|fatal"
            }
        }
        for (column in target_columns) {
            table = target_column_tables[column]
            if (!(column in oracle_columns) && (table in oracle_tables)) {
                print column "|unexpected " column "|fatal"
            }
        }
        for (table in target_tables) {
            if (!(table in oracle_tables)) {
                print table "|informational target-only table " table "|informational"
            }
        }
    }
' "$comparison_input" | LC_ALL=C sort -t'|' -k1,1 > "$differences_file"

while IFS='|' read -r _ message _; do
    [ -n "$message" ] || continue
    log "$message"
done < "$differences_file"

fatal_difference_count="$(
    awk -F'|' '$3 == "fatal" { count++ } END { print count + 0 }' "$differences_file"
)"
if [ "$fatal_difference_count" -gt 0 ]; then
    exit 1
fi

log "no local schema drift"
