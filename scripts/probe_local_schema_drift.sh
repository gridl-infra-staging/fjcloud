#!/usr/bin/env bash
# Compare the local database with a migration-built oracle for public columns
# and migration-seeded reference values.

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

require_local_database_host() {
    local database_url="$1" host

    host="$(require_db_url_part "$database_url" db_url_host)" || {
        log "DATABASE_URL must include a hostname"
        return 1
    }

    case "$host" in
        localhost|127.0.0.1|[::1])
            return 0
            ;;
    esac

    log "DATABASE_URL must point to a local PostgreSQL host (localhost, 127.0.0.1, or [::1])"
    return 1
}

if [ -z "${DATABASE_URL:-}" ]; then
    log "DATABASE_URL is not set. Run: source .env.local"
    exit 1
fi

require_local_database_host "$DATABASE_URL" || exit 1

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

reference_table="rate_cards"
reference_row_key="launch-2026"
reference_column="shared_minimum_spend_cents"

reference_values_sql="
SELECT '$reference_table', name, '$reference_column', $reference_column
FROM $reference_table
WHERE name = '$reference_row_key'
  AND effective_until IS NULL
ORDER BY name"

comparison_dir="$(mktemp -d "${TMPDIR:-/tmp}/fjcloud_schema_drift.XXXXXX")"
comparison_input="$comparison_dir/columns"
reference_values_input="$comparison_dir/reference_values"
differences_file="$comparison_dir/differences"
unsorted_differences_file="$comparison_dir/differences_unsorted"

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
' "$comparison_input" > "$unsorted_differences_file"

oracle_reference_status=0
target_reference_status=0
oracle_reference_values=""
target_reference_values=""

if ! oracle_reference_values="$(psql "$scratch_database_url" -tAc "$reference_values_sql")"; then
    oracle_reference_status=1
fi
if ! target_reference_values="$(psql "$DATABASE_URL" -tAc "$reference_values_sql")"; then
    target_reference_status=1
fi

if [ "$oracle_reference_status" -ne 0 ]; then
    printf '%s\n' \
        "reference_values.oracle|Failed to inspect scratch reference-value oracle|fatal" \
        >> "$unsorted_differences_file"
fi
if [ "$target_reference_status" -ne 0 ]; then
    printf '%s\n' \
        "reference_values.target|Failed to inspect target reference values|fatal" \
        >> "$unsorted_differences_file"
fi

# run_migrations_with_runner seeds migration history for pre-tracking databases,
# so a target can claim migrations ran without receiving reference-row updates.
if [ "$oracle_reference_status" -eq 0 ] && [ "$target_reference_status" -eq 0 ]; then
    printf '%s\n' "$oracle_reference_values" |
        awk -F'|' 'NF >= 4 { print "oracle|" $1 "|" $2 "|" $3 "|" $4 }' > "$reference_values_input"
    printf '%s\n' "$target_reference_values" |
        awk -F'|' 'NF >= 4 { print "target|" $1 "|" $2 "|" $3 "|" $4 }' >> "$reference_values_input"

    awk -F'|' \
        -v required_table="$reference_table" \
        -v required_row="$reference_row_key" \
        -v required_column="$reference_column" '
        $1 == "oracle" {
            oracle_row_count++
            oracle_value = $5
            next
        }
        $1 == "target" {
            target_row_count++
            target_value = $5
        }
        END {
            required_key = required_table "." required_row "." required_column
            if (oracle_row_count == 0) {
                print required_key "|missing oracle row " required_table " row " required_row " column " required_column " expected <present> found <missing>|fatal"
            } else if (oracle_row_count > 1) {
                print required_key "|duplicate oracle rows " required_table " row " required_row " column " required_column " expected exactly 1 found " oracle_row_count "|fatal"
            }

            if (target_row_count == 0 && oracle_row_count > 0) {
                print required_key "|missing row " required_table " row " required_row " column " required_column " expected " oracle_value " found <missing>|fatal"
            } else if (target_row_count > 1) {
                print required_key "|duplicate target rows " required_table " row " required_row " column " required_column " expected exactly 1 found " target_row_count "|fatal"
            }

            if (oracle_row_count == 1 && target_row_count == 1 && target_value != oracle_value) {
                print required_key "|value mismatch " required_table " row " required_row " column " required_column " expected " oracle_value " found " target_value "|fatal"
            }
        }
    ' "$reference_values_input" >> "$unsorted_differences_file"
fi

LC_ALL=C sort -t'|' -k1,1 "$unsorted_differences_file" > "$differences_file"

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
