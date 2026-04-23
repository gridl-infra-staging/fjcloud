#!/usr/bin/env bash
# Metering validation checks for the backend launch gate.
#
# Each check function uses live_gate_require to enforce preconditions:
#   - Gate ON  (BACKEND_LIVE_GATE=1): failure = exit 1 (hard block)
#   - Gate OFF: failure = [skip] message + continue
#
# Functions:
#   check_usage_records_populated  — usage_records table has rows
#   check_rollup_current           — usage_daily has been rolled up recently
#
# REASON: codes:
#   db_url_missing       No database URL configured
#   db_connection_timeout Database connection failed or timed out
#   db_query_timeout     Database query exceeded statement_timeout
#   db_query_failed      Database query failed for a non-timeout reason
#   usage_records_empty  usage_records count is zero or invalid
#   rollup_stale         usage_daily has no rollups within freshness window

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/live_gate.sh"

# --------------------------------------------------------------------------
# Helper: resolve the database connection URL
# --------------------------------------------------------------------------
_metering_db_url() {
    local url="${INTEGRATION_DB_URL:-${DATABASE_URL:-}}"
    echo "$url"
}

_METERING_QUERY_OUTPUT=""

_run_metering_query() {
    local db_url="$1"
    local sql="$2"
    local output psql_status=0

    if output="$(_gate_timeout "${GATE_INNER_TIMEOUT_SEC:-10}" \
        env PGCONNECTTIMEOUT=5 psql -tAq "$db_url" \
        -c "SET statement_timeout TO 10000" \
        -c "$sql" 2>&1)"; then
        psql_status=0
    else
        psql_status=$?
    fi

    _METERING_QUERY_OUTPUT="$output"

    if [ "$psql_status" -eq 0 ]; then
        return 0
    fi

    if [ "$psql_status" -eq 124 ]; then
        return 124
    fi

    if echo "$output" | grep -Eqi 'statement timeout|canceling statement due to statement timeout'; then
        return 20
    fi

    if echo "$output" | grep -Eqi 'could not connect|connection refused|timeout expired|no route to host|could not translate host name'; then
        return 21
    fi
    return 22
}

_handle_metering_query_failure() {
    local query_label="$1"
    local query_status="$2"
    case "$query_status" in
        20)
            live_gate_fail_with_reason "db_query_timeout" \
                "Database statement timeout while checking $query_label"
            ;;
        21)
            live_gate_fail_with_reason "db_connection_timeout" \
                "Database connection timed out or failed while checking $query_label"
            ;;
        *)
            live_gate_fail_with_reason "db_query_failed" \
                "Database query failed before returning data while checking $query_label"
            ;;
    esac
}

_handle_metering_query_status() {
    local query_label="$1"
    local query_status="$2"

    if [ "$query_status" -eq 124 ]; then
        echo "REASON: db_connection_timeout" >&2
        exit 124
    fi

    _handle_metering_query_failure "$query_label" "$query_status"
}

# --------------------------------------------------------------------------
# check_usage_records_populated
# Verifies the usage_records table has at least one row via psql.
# --------------------------------------------------------------------------
check_usage_records_populated() {
    local db_url
    db_url="$(_metering_db_url)"

    if [ -z "${db_url:-}" ]; then
        live_gate_fail_with_reason "db_url_missing" "No database URL set (INTEGRATION_DB_URL or DATABASE_URL) — cannot check usage_records"
        return 0
    fi

    local row_count
    if _run_metering_query "$db_url" "SELECT COUNT(*) FROM usage_records"; then
        row_count="$_METERING_QUERY_OUTPUT"
    else
        local query_status="$?"
        _handle_metering_query_status "usage_records" "$query_status"
        return 0
    fi
    row_count="$(echo "$row_count" | tr -d '[:space:]')"
    if ! [[ "${row_count:-}" =~ ^[0-9]+$ ]]; then
        row_count="0"
    fi

    if [ "${row_count:-0}" -le 0 ]; then
        live_gate_fail_with_reason "usage_records_empty" "usage_records table is empty (found $row_count rows) — metering agent may not be capturing data"
        return 0
    fi
}

# --------------------------------------------------------------------------
# check_rollup_current
# Verifies usage_daily has been rolled up within the expected freshness
# window (48 hours). Queries for rows with aggregated_at within that window.
# --------------------------------------------------------------------------
check_rollup_current() {
    local db_url
    db_url="$(_metering_db_url)"

    if [ -z "${db_url:-}" ]; then
        live_gate_fail_with_reason "db_url_missing" "No database URL set (INTEGRATION_DB_URL or DATABASE_URL) — cannot check usage_daily"
        return 0
    fi

    local recent_count
    if _run_metering_query "$db_url" \
        "SELECT COUNT(*) FROM usage_daily WHERE aggregated_at >= NOW() - INTERVAL '48 hours'"; then
        recent_count="$_METERING_QUERY_OUTPUT"
    else
        local query_status="$?"
        _handle_metering_query_status "usage_daily" "$query_status"
        return 0
    fi
    recent_count="$(echo "$recent_count" | tr -d '[:space:]')"
    if ! [[ "${recent_count:-}" =~ ^[0-9]+$ ]]; then
        recent_count="0"
    fi

    if [ "${recent_count:-0}" -le 0 ]; then
        live_gate_fail_with_reason "rollup_stale" "usage_daily has no recent rollups (0 rows within 48h) — aggregation job may not be running"
        return 0
    fi
}
