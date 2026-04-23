#!/usr/bin/env bash
# Validate metering pipeline health against a live database and emit JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation_json.sh"

append_check() {
    local name="$1"
    local passed="$2"
    local detail="$3"
    local reason="${4:-}"

    local detail_json
    detail_json="$(validation_json_escape "$detail")"

    local check
    if [ -n "$reason" ]; then
        local reason_json
        reason_json="$(validation_json_escape "$reason")"
        check="{\"name\":\"$name\",\"passed\":$passed,\"detail\":$detail_json,\"reason\":$reason_json}"
    else
        check="{\"name\":\"$name\",\"passed\":$passed,\"detail\":$detail_json}"
    fi

    if [ -z "$CHECKS_JSON" ]; then
        CHECKS_JSON="$check"
    else
        CHECKS_JSON="$CHECKS_JSON,$check"
    fi
}

emit_result() {
    local passed="$1"
    local elapsed_ms
    elapsed_ms=$(( $(validation_ms_now) - START_MS ))
    printf '{"passed":%s,"checks":[%s],"elapsed_ms":%s}\n' "$passed" "$CHECKS_JSON" "$elapsed_ms"
}

trim() {
    echo "$1" | tr -d '[:space:]'
}

to_int_or_zero() {
    local value
    value="$(trim "$1")"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
    else
        echo "0"
    fi
}

run_query() {
    local sql="$1"
    psql -tAq "$DB_URL" -c "$sql" 2>/dev/null || true
}

START_MS="$(validation_ms_now)"
CHECKS_JSON=""
DB_URL="${INTEGRATION_DB_URL:-${DATABASE_URL:-}}"

if [ -z "$DB_URL" ]; then
    append_check "database_url_present" false "Neither INTEGRATION_DB_URL nor DATABASE_URL is set" "db_url_missing"
    emit_result false
    exit 1
fi

usage_count="$(to_int_or_zero "$(run_query "SELECT COUNT(*) FROM usage_records")")"
latest_usage="$(run_query "SELECT COALESCE(MAX(created_at)::text, '') FROM usage_records")"
latest_usage="$(trim "$latest_usage")"

rollup_count="$(to_int_or_zero "$(run_query "SELECT COUNT(*) FROM usage_daily")")"
latest_rollup="$(run_query "SELECT COALESCE(MAX(aggregated_at)::text, '') FROM usage_daily")"
latest_rollup="$(trim "$latest_rollup")"

fresh_rollup_count="$(to_int_or_zero "$(run_query "SELECT COUNT(*) FROM usage_daily WHERE aggregated_at >= (SELECT MAX(created_at) - INTERVAL '48 hours' FROM usage_records)")")"
overlap_customer_count="$(to_int_or_zero "$(run_query "SELECT COUNT(*) FROM (SELECT DISTINCT u.customer_id FROM usage_records u INNER JOIN usage_daily d ON d.customer_id = u.customer_id) t")")"

all_passed=true

if [ "$usage_count" -gt 0 ]; then
    append_check "usage_records_populated" true "usage_records count=$usage_count latest_created_at=${latest_usage:-unknown}"
else
    append_check "usage_records_populated" false "usage_records has no rows" "usage_records_empty"
    all_passed=false
fi

if [ "$rollup_count" -gt 0 ]; then
    append_check "usage_daily_populated" true "usage_daily count=$rollup_count latest_aggregated_at=${latest_rollup:-unknown}"
else
    append_check "usage_daily_populated" false "usage_daily has no rows" "usage_daily_empty"
    all_passed=false
fi

if [ "$fresh_rollup_count" -gt 0 ]; then
    append_check "rollup_freshness" true "Found $fresh_rollup_count rollups within 48h of latest usage_records data"
else
    append_check "rollup_freshness" false "No rollups within 48h of latest usage_records data" "rollup_stale"
    all_passed=false
fi

if [ "$overlap_customer_count" -gt 0 ]; then
    append_check "raw_and_rollup_customer_overlap" true "Found $overlap_customer_count customer(s) with both raw and rolled-up data"
else
    append_check "raw_and_rollup_customer_overlap" false "No customer has both raw and rolled-up data" "customer_overlap_missing"
    all_passed=false
fi

if [ "$all_passed" = true ]; then
    emit_result true
    exit 0
fi

emit_result false
exit 1
