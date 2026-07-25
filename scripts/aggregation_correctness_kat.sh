#!/usr/bin/env bash
# Real-pipeline aggregation correctness known-answer test.
#
# W2's local_real_pipeline_run.sh remains the owner of stack lifecycle, target
# resolution, traffic, scrape bracketing, aggregation, evidence construction,
# and teardown. This wrapper composes that owner and adds zero-tolerance
# assertions that the produced usage_daily counters equal the independent
# hand-calculated traffic counts and same-day raw usage_records sums.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LRP_DRIVE_WRITES=11
LRP_DRIVE_SEARCHES=5

# shellcheck source=lib/local_real_pipeline_run.sh
source "$SCRIPT_DIR/lib/local_real_pipeline_run.sh"

KAT_TRAFFIC_KEY_WRITES=1
KAT_SEED_WRITE_OPERATIONS=25000
KAT_SEED_SEARCH_REQUESTS=250000
KAT_EXPECTED_WRITES=""
KAT_EXPECTED_SEARCHES=""
KAT_DAILY_ROW_COUNT=""
KAT_DAILY_WRITE_OPERATIONS=""
KAT_DAILY_SEARCH_REQUESTS=""
KAT_RAW_WRITE_SUM=""
KAT_RAW_SEARCH_SUM=""

kat_fail() {
    local reason="$1"
    shift
    printf 'AGGREGATION_CORRECTNESS_KAT: FAIL reason=%s' "$reason"
    if [ "$#" -gt 0 ]; then
        printf ' %s' "$*"
    fi
    printf '\n'
    exit 1
}

kat_is_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

kat_require_non_negative_integer() {
    local field="$1" value="$2"
    kat_is_non_negative_integer "$value" \
        || kat_fail non_integer_field "field=${field} actual=${value:-null}"
}

kat_require_equal() {
    local reason="$1" expected="$2" actual="$3"
    [ "$actual" = "$expected" ] \
        || kat_fail "$reason" "expected=${expected} actual=${actual}"
}

kat_compute_expected_counters() {
    kat_require_non_negative_integer LRP_DRIVE_WRITES "$LRP_DRIVE_WRITES"
    kat_require_non_negative_integer LRP_DRIVE_SEARCHES "$LRP_DRIVE_SEARCHES"
    KAT_EXPECTED_WRITES=$((KAT_TRAFFIC_KEY_WRITES + LRP_DRIVE_WRITES))
    KAT_EXPECTED_SEARCHES="$LRP_DRIVE_SEARCHES"
}

kat_run_pipeline_until_evidence() {
    lrp_prepare_env
    lrp_create_evidence_file_and_trap
    lrp_bring_up_stack
    lrp_resolve_target
    lrp_capture_and_clear
    lrp_start_agent_and_read_pre
    lrp_drive_traffic
    lrp_await_delta_and_read_post
    lrp_aggregate
    lrp_build_evidence
}

kat_require_classifier_pass() {
    local classifier_output classifier_rc
    classifier_output="$(
        bash "$SCRIPT_DIR/local_real_pipeline_probe.sh" \
            --assert-evidence "$LRP_EVIDENCE_FILE" 2>&1
    )"
    classifier_rc=$?

    if [ -n "$classifier_output" ]; then
        printf '%s\n' "$classifier_output"
    fi
    if [ "$classifier_rc" -ne 0 ]; then
        kat_fail classifier_failed \
            "expected=LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified actual_rc=${classifier_rc} actual_output=${classifier_output:-empty}"
    fi
    [ "$classifier_output" = "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified" ] \
        || kat_fail classifier_malformed \
            "expected=LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified actual_output=${classifier_output:-empty}"
}

kat_query_counter_values() {
    local sql row field_count customer_sql region_sql target_date_sql target_start_expr
    customer_sql="$(lrp_pg_text_literal "$LRP_CUSTOMER_ID")"
    region_sql="$(lrp_pg_text_literal "$LRP_DRIVEN_REGION")"
    target_date_sql="$(lrp_pg_text_literal "$LRP_TARGET_DATE")"
    target_start_expr="$(lrp_pg_utc_day_start_expr "$LRP_TARGET_DATE")"

    printf -v sql "WITH scoped_daily AS (SELECT write_operations, search_requests FROM usage_daily WHERE customer_id=%s AND region=%s AND date=%s::date), daily AS (SELECT count(*)::text AS daily_row_count, COALESCE(min(write_operations)::text, '') AS daily_write_operations, COALESCE(min(search_requests)::text, '') AS daily_search_requests FROM scoped_daily), raw AS (SELECT COALESCE(SUM(CASE WHEN event_type = 'write_operations' THEN value ELSE 0 END), 0)::text AS raw_write_sum, COALESCE(SUM(CASE WHEN event_type = 'search_requests' THEN value ELSE 0 END), 0)::text AS raw_search_sum FROM usage_records WHERE customer_id=%s AND region=%s AND recorded_at >= %s AND recorded_at < (%s + interval '1 day')) SELECT daily_row_count, daily_write_operations, daily_search_requests, raw_write_sum, raw_search_sum FROM daily CROSS JOIN raw" \
        "$customer_sql" "$region_sql" "$target_date_sql" \
        "$customer_sql" "$region_sql" "$target_start_expr" "$target_start_expr"

    row="$(run_local_psql -v ON_ERROR_STOP=1 -tAF '|' -c "$sql" 2>/dev/null)" \
        || kat_fail kat_query_failed \
            "scope_customer=${LRP_CUSTOMER_ID} scope_region=${LRP_DRIVEN_REGION} target_date=${LRP_TARGET_DATE}"
    case "$row" in
        *$'\n'*)
            kat_fail kat_query_malformed "expected_rows=1 actual_rows=multiple"
            ;;
    esac
    field_count="$(awk -F'|' 'NR == 1 { print NF }' <<<"$row")"
    [ "$field_count" = "5" ] \
        || kat_fail kat_query_malformed "expected_fields=5 actual_fields=${field_count:-0}"

    IFS='|' read -r \
        KAT_DAILY_ROW_COUNT \
        KAT_DAILY_WRITE_OPERATIONS \
        KAT_DAILY_SEARCH_REQUESTS \
        KAT_RAW_WRITE_SUM \
        KAT_RAW_SEARCH_SUM <<<"$row"
}

kat_assert_counter_values() {
    kat_require_non_negative_integer daily_row_count "$KAT_DAILY_ROW_COUNT"
    kat_require_equal daily_row_count_mismatch 1 "$KAT_DAILY_ROW_COUNT"

    kat_require_non_negative_integer daily_write_operations "$KAT_DAILY_WRITE_OPERATIONS"
    kat_require_non_negative_integer daily_search_requests "$KAT_DAILY_SEARCH_REQUESTS"
    kat_require_non_negative_integer raw_write_sum "$KAT_RAW_WRITE_SUM"
    kat_require_non_negative_integer raw_search_sum "$KAT_RAW_SEARCH_SUM"

    if [ "$KAT_DAILY_WRITE_OPERATIONS" = "$KAT_SEED_WRITE_OPERATIONS" ] \
        && [ "$KAT_DAILY_SEARCH_REQUESTS" = "$KAT_SEED_SEARCH_REQUESTS" ]; then
        kat_fail seed_values_survived \
            "rejected_write_operations=${KAT_SEED_WRITE_OPERATIONS} rejected_search_requests=${KAT_SEED_SEARCH_REQUESTS}"
    fi

    kat_require_equal daily_write_mismatch "$KAT_EXPECTED_WRITES" "$KAT_DAILY_WRITE_OPERATIONS"
    kat_require_equal daily_search_mismatch "$KAT_EXPECTED_SEARCHES" "$KAT_DAILY_SEARCH_REQUESTS"
    kat_require_equal raw_write_sum_mismatch "$KAT_EXPECTED_WRITES" "$KAT_RAW_WRITE_SUM"
    kat_require_equal raw_search_sum_mismatch "$KAT_EXPECTED_SEARCHES" "$KAT_RAW_SEARCH_SUM"
    kat_require_equal raw_write_daily_mismatch "$KAT_DAILY_WRITE_OPERATIONS" "$KAT_RAW_WRITE_SUM"
    kat_require_equal raw_search_daily_mismatch "$KAT_DAILY_SEARCH_REQUESTS" "$KAT_RAW_SEARCH_SUM"
}

kat_emit_pass() {
    printf 'AGGREGATION_CORRECTNESS_KAT: PASS pipeline_executed=true driven_writes=%s driven_searches=%s write_arithmetic=%s+%s=%s expected_searches=%s daily_write_operations=%s daily_search_requests=%s raw_write_sum=%s raw_search_sum=%s customer_id=%s region=%s target_date=%s\n' \
        "$LRP_DRIVE_WRITES" "$LRP_DRIVE_SEARCHES" \
        "$KAT_TRAFFIC_KEY_WRITES" "$LRP_DRIVE_WRITES" "$KAT_EXPECTED_WRITES" \
        "$KAT_EXPECTED_SEARCHES" \
        "$KAT_DAILY_WRITE_OPERATIONS" "$KAT_DAILY_SEARCH_REQUESTS" \
        "$KAT_RAW_WRITE_SUM" "$KAT_RAW_SEARCH_SUM" \
        "$LRP_CUSTOMER_ID" "$LRP_DRIVEN_REGION" "$LRP_TARGET_DATE"
}

main() {
    kat_compute_expected_counters
    kat_run_pipeline_until_evidence
    kat_require_classifier_pass
    kat_query_counter_values
    kat_assert_counter_values
    kat_emit_pass
}

main "$@"
