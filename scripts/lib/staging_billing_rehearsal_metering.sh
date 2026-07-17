#!/usr/bin/env bash
# Metering evidence helpers for staging billing rehearsal.

extract_reason_code() {
    local check_output="$1"
    local reason_line
    reason_line="$(printf '%s\n' "$check_output" | grep -m1 '^REASON:' || true)"
    if [ -n "$reason_line" ]; then
        _strip_reason_prefix "$reason_line"
    else
        printf 'metering_check_failed\n'
    fi
}

metering_sql_for_check() {
    case "$1" in
        check_usage_records_populated)
            metering_usage_records_populated_sql
            ;;
        check_rollup_current)
            metering_rollup_current_sql
            ;;
        *)
            return 1
            ;;
    esac
}

metering_empty_reason_for_check() {
    case "$1" in
        check_usage_records_populated) printf '%s\n' "usage_records_empty" ;;
        check_rollup_current) printf '%s\n' "rollup_stale" ;;
        *) printf '%s\n' "metering_check_failed" ;;
    esac
}

metering_query_failure_reason() {
    case "$1" in
        20) printf '%s\n' "db_query_timeout" ;;
        21|124) printf '%s\n' "db_connection_timeout" ;;
        30) printf '%s\n' "db_url_missing" ;;
        *) printf '%s\n' "db_query_failed" ;;
    esac
}

set_metering_failure() {
    local classification="$1"
    local detail="$2"

    STEP_METERING_RESULT="blocked"
    STEP_METERING_CLASSIFICATION="$classification"
    STEP_METERING_DETAIL="$detail"
    SUMMARY_RESULT="blocked"
    SUMMARY_CLASSIFICATION="$classification"
    SUMMARY_DETAIL="Metering evidence failed and blocked live mutation."
}

run_remote_metering_check() {
    local check_fn="$1"
    local check_label="$2"
    local sql query_status row_count reason_code

    sql="$(metering_sql_for_check "$check_fn")" || {
        set_metering_failure "metering_check_failed" "${check_label} has no remote SQL mapping."
        return 1
    }

    if run_rehearsal_staging_db_query "$sql"; then
        row_count="$(printf '%s\n' "$REHEARSAL_QUERY_OUTPUT" | tr -d '[:space:]')"
        if [[ "$row_count" =~ ^[0-9]+$ ]] && [ "$row_count" -gt 0 ]; then
            return 0
        fi
        reason_code="$(metering_empty_reason_for_check "$check_fn")"
        set_metering_failure "$reason_code" "${check_label} failed through staging DB query owner: count=${row_count:-0}"
        return 1
    fi

    query_status=$?
    reason_code="$(metering_query_failure_reason "$query_status")"
    set_metering_failure "$reason_code" "${check_label} failed through staging DB query owner: ${REHEARSAL_QUERY_OUTPUT}"
    return 1
}

run_metering_check() {
    local check_fn="$1"
    local check_label="$2"
    local check_output="" check_exit=0 reason_code=""

    if [ -z "$(_metering_db_url)" ]; then
        run_remote_metering_check "$check_fn" "$check_label"
        return $?
    fi

    set +e
    check_output="$(
        (
            export BACKEND_LIVE_GATE=1
            "$check_fn"
        ) 2>&1
    )"
    check_exit=$?
    set -e

    if [ "$check_exit" -eq 0 ]; then
        return 0
    fi

    reason_code="$(extract_reason_code "$check_output")"
    set_metering_failure "$reason_code" "${check_label} failed: ${check_output}"
    return 1
}

run_metering_evidence_step() {
    if ! run_metering_check "check_usage_records_populated" "usage_records check"; then
        return 1
    fi
    if ! run_metering_check "check_rollup_current" "usage_daily freshness check"; then
        return 1
    fi

    STEP_METERING_RESULT="passed"
    STEP_METERING_CLASSIFICATION="metering_evidence_ready"
    STEP_METERING_DETAIL="usage_records and usage_daily checks passed."
    return 0
}
