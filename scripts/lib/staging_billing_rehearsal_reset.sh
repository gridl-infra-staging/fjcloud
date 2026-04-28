#!/usr/bin/env bash
# Reset-path helpers for staging billing rehearsal.

RESET_STRIPE_CUSTOMER_ID=""
RESET_DB_INVOICE_ROWS_JSON='[]'
RESET_STRIPE_CLEARED_IDS_JSON='[]'
RESET_DB_DELETE_INVOICE_IDS_JSON='[]'
RESET_STRIPE_BLOCKED_CLASSIFICATION=""
RESET_STRIPE_BLOCKED_DETAIL=""
RESET_PAID_DB_ONLY_CLEANUP=0
RESET_LOCAL_ONLY_DB_CLEANUP=0

set_reset_blocked_summary() {
    local classification="$1"
    local detail="$2"
    SUMMARY_RESULT="blocked"
    SUMMARY_CLASSIFICATION="$classification"
    SUMMARY_DETAIL="$detail"
    STEP_GUARD_RESULT="blocked"
    STEP_GUARD_CLASSIFICATION="$classification"
    STEP_GUARD_DETAIL="$detail"
    STEP_ATTEMPT_RESULT="blocked"
    STEP_ATTEMPT_CLASSIFICATION="$classification"
    STEP_ATTEMPT_DETAIL="Reset flow was not completed."
}

set_reset_completed_summary() {
    local detail="$1"
    SUMMARY_RESULT="passed"
    SUMMARY_CLASSIFICATION="reset_completed"
    SUMMARY_DETAIL="$detail"
    STEP_PREFLIGHT_RESULT="passed"
    STEP_PREFLIGHT_CLASSIFICATION="reset_mode"
    STEP_PREFLIGHT_DETAIL="Preflight owner skipped in reset-only mode."
    STEP_METERING_RESULT="passed"
    STEP_METERING_CLASSIFICATION="reset_mode"
    STEP_METERING_DETAIL="Metering evidence skipped in reset-only mode."
    STEP_GUARD_RESULT="passed"
    STEP_GUARD_CLASSIFICATION="reset_mode"
    STEP_GUARD_DETAIL="Reset allowlist and tenant confirmation gate passed."
    STEP_ATTEMPT_RESULT="passed"
    STEP_ATTEMPT_CLASSIFICATION="reset_mode"
    STEP_ATTEMPT_DETAIL="$detail"
}

reset_set_db_query_failure() {
    local classification_prefix="$1"
    local query_status="$2"
    if [ "$query_status" -eq 124 ] || [ "$query_status" -eq 20 ]; then
        set_reset_blocked_summary "${classification_prefix}_query_failed" "${classification_prefix} query timed out."
        return
    fi
    if [ "$query_status" -eq 21 ]; then
        set_reset_blocked_summary "${classification_prefix}_query_failed" "${classification_prefix} query could not connect to Postgres."
        return
    fi
    if [ "$query_status" -eq 30 ]; then
        set_reset_blocked_summary "${classification_prefix}_query_failed" "${classification_prefix} query has no database URL."
        return
    fi
    set_reset_blocked_summary "${classification_prefix}_query_failed" "${classification_prefix} query failed: ${REHEARSAL_QUERY_OUTPUT}"
}

allowlist_contains_tenant_uuid() {
    python3 - "$1" "$2" <<'PY'
import sys

tenant = sys.argv[1].strip()
allowlist = [item.strip() for item in sys.argv[2].split(",")]
print("true" if tenant and tenant in allowlist else "false")
PY
}

validate_test_tenant_allowlist() {
    if [ "$RESET_TEST_STATE" -ne 1 ]; then
        return 0
    fi

    local allowlist="${FJCLOUD_TEST_TENANT_IDS:-}"
    if [ -z "$allowlist" ]; then
        set_reset_blocked_summary "test_tenant_allowlist_missing" \
            "FJCLOUD_TEST_TENANT_IDS must be set in the explicit env file for reset mode."
        return 1
    fi

    if [ "$(allowlist_contains_tenant_uuid "$CONFIRM_TEST_TENANT_ID" "$allowlist")" != "true" ]; then
        set_reset_blocked_summary "test_tenant_not_allowlisted" \
            "Tenant ${CONFIRM_TEST_TENANT_ID} is not present in FJCLOUD_TEST_TENANT_IDS."
        return 1
    fi
    return 0
}

reset_month_value() {
    if [ -n "$BILLING_MONTH" ]; then
        printf '%s\n' "$BILLING_MONTH"
    else
        date -u +%Y-%m
    fi
}

reset_month_bounds() {
    python3 - "$1" <<'PY'
import sys

month = sys.argv[1]
year = int(month.split("-")[0])
mon = int(month.split("-")[1])
next_year = year + 1 if mon == 12 else year
next_mon = 1 if mon == 12 else mon + 1
print(f"{year:04d}-{mon:02d}-01")
print(f"{next_year:04d}-{next_mon:02d}-01")
PY
}

reset_invoice_rows_json_from_query_output() {
    python3 - "$REHEARSAL_QUERY_OUTPUT" <<'PY' || true
import json
import sys

rows = []
for raw in sys.argv[1].splitlines():
    line = raw.strip()
    if not line:
        continue
    parts = line.split("|")
    while len(parts) < 2:
        parts.append("")
    rows.append({
        "invoice_id": parts[0].strip(),
        "stripe_invoice_id": parts[1].strip(),
    })
print(json.dumps(rows))
PY
}

reset_rows_to_lines() {
    python3 - "$1" <<'PY'
import json
import sys

rows = json.loads(sys.argv[1])
for row in rows:
    invoice_id = str(row.get("invoice_id", "")).strip()
    stripe_invoice_id = str(row.get("stripe_invoice_id", "")).strip()
    print(f"{invoice_id}|{stripe_invoice_id}")
PY
}

stripe_status_for_invoice_id() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
target = sys.argv[2]
for item in payload.get("data", []):
    if not isinstance(item, dict):
        continue
    if str(item.get("id", "")).strip() == target:
        print(str(item.get("status", "")).strip())
        raise SystemExit(0)
print("")
PY
}

newline_list_to_json_array() {
    python3 - "$1" <<'PY'
import json
import sys

values = [line.strip() for line in sys.argv[1].splitlines() if line.strip()]
deduped = []
for item in values:
    if item not in deduped:
        deduped.append(item)
print(json.dumps(deduped))
PY
}

run_reset_customer_lookup() {
    local sql query_status
    sql="SELECT stripe_customer_id FROM customers WHERE id = '$CONFIRM_TEST_TENANT_ID' /* stage4_reset_customer_lookup */"
    if run_rehearsal_db_query "$sql"; then
        :
    else
        query_status=$?
        reset_set_db_query_failure "reset_customer_lookup" "$query_status"
        return 1
    fi

    RESET_STRIPE_CUSTOMER_ID="$(printf '%s\n' "$REHEARSAL_QUERY_OUTPUT" | head -1 | tr -d '[:space:]')"
    if [ -z "$RESET_STRIPE_CUSTOMER_ID" ]; then
        set_reset_blocked_summary "test_tenant_not_found" \
            "No stripe_customer_id was found for tenant ${CONFIRM_TEST_TENANT_ID}."
        return 1
    fi
    return 0
}

run_reset_invoice_rows_query() {
    local month_bounds month_start month_end sql query_status
    month_bounds="$(reset_month_bounds "$(reset_month_value)")"
    month_start="$(printf '%s\n' "$month_bounds" | sed -n '1p')"
    month_end="$(printf '%s\n' "$month_bounds" | sed -n '2p')"

    sql="SELECT i.id::text || '|' || COALESCE(i.stripe_invoice_id,'') FROM invoices i WHERE i.customer_id = '$CONFIRM_TEST_TENANT_ID'::uuid AND i.period_start >= DATE '$month_start' AND i.period_start < DATE '$month_end' /* stage4_reset_invoice_rows */"
    if run_rehearsal_db_query "$sql"; then
        RESET_DB_INVOICE_ROWS_JSON="$(reset_invoice_rows_json_from_query_output)"
        return 0
    fi
    query_status=$?
    reset_set_db_query_failure "reset_invoice_rows" "$query_status"
    return 1
}

run_reset_stripe_cleanup() {
    local stripe_list_output stripe_list_status timeout_sec
    local line stripe_invoice_id stripe_status
    local invoice_id cleared_ids_raw="" delete_invoice_ids_raw="" had_blockers=0

    RESET_STRIPE_CLEARED_IDS_JSON='[]'
    RESET_DB_DELETE_INVOICE_IDS_JSON='[]'
    RESET_STRIPE_BLOCKED_CLASSIFICATION=""
    RESET_STRIPE_BLOCKED_DETAIL=""
    RESET_PAID_DB_ONLY_CLEANUP=0
    RESET_LOCAL_ONLY_DB_CLEANUP=0

    timeout_sec="$(rehearsal_http_timeout_sec)"
    set +e
    stripe_list_output="$(_gate_timeout "$timeout_sec" stripe invoices list --customer "$RESET_STRIPE_CUSTOMER_ID" --limit 100 --format json)"
    stripe_list_status=$?
    set -e
    if [ "$stripe_list_status" -ne 0 ]; then
        set_reset_blocked_summary "reset_stripe_list_failed" "Stripe invoice list failed for ${RESET_STRIPE_CUSTOMER_ID}."
        return 1
    fi
    if ! is_valid_json "$stripe_list_output"; then
        set_reset_blocked_summary "reset_stripe_list_invalid" "Stripe invoice list returned invalid JSON."
        return 1
    fi

    while IFS= read -r line; do
        invoice_id="${line%%|*}"
        stripe_invoice_id="${line#*|}"

        if [ -z "$stripe_invoice_id" ]; then
            if [ -n "$invoice_id" ]; then
                delete_invoice_ids_raw="${delete_invoice_ids_raw}${invoice_id}"$'\n'
                RESET_LOCAL_ONLY_DB_CLEANUP=1
            fi
            continue
        fi

        stripe_status="$(stripe_status_for_invoice_id "$stripe_list_output" "$stripe_invoice_id")"
        if [ -z "$stripe_status" ]; then
            RESET_STRIPE_BLOCKED_CLASSIFICATION="reset_stripe_invoice_missing"
            RESET_STRIPE_BLOCKED_DETAIL="Stripe invoice ${stripe_invoice_id} was not returned by stripe invoices list."
            had_blockers=1
            continue
        fi

        case "$stripe_status" in
            draft)
                stripe invoices delete "$stripe_invoice_id" >/dev/null 2>&1 || {
                    RESET_STRIPE_BLOCKED_CLASSIFICATION="reset_stripe_mutation_failed"
                    RESET_STRIPE_BLOCKED_DETAIL="Stripe delete failed for invoice ${stripe_invoice_id}."
                    had_blockers=1
                    continue
                }
                cleared_ids_raw="${cleared_ids_raw}${stripe_invoice_id}"$'\n'
                ;;
            open|uncollectible)
                stripe invoices void "$stripe_invoice_id" >/dev/null 2>&1 || {
                    RESET_STRIPE_BLOCKED_CLASSIFICATION="reset_stripe_mutation_failed"
                    RESET_STRIPE_BLOCKED_DETAIL="Stripe void failed for invoice ${stripe_invoice_id}."
                    had_blockers=1
                    continue
                }
                cleared_ids_raw="${cleared_ids_raw}${stripe_invoice_id}"$'\n'
                ;;
            paid)
                cleared_ids_raw="${cleared_ids_raw}${stripe_invoice_id}"$'\n'
                RESET_PAID_DB_ONLY_CLEANUP=1
                ;;
            void|deleted)
                cleared_ids_raw="${cleared_ids_raw}${stripe_invoice_id}"$'\n'
                ;;
            *)
                RESET_STRIPE_BLOCKED_CLASSIFICATION="reset_stripe_status_unsupported"
                RESET_STRIPE_BLOCKED_DETAIL="Unsupported Stripe invoice status '${stripe_status}' for ${stripe_invoice_id}."
                had_blockers=1
                ;;
        esac
    done < <(reset_rows_to_lines "$RESET_DB_INVOICE_ROWS_JSON")

    RESET_STRIPE_CLEARED_IDS_JSON="$(newline_list_to_json_array "$cleared_ids_raw")"
    RESET_DB_DELETE_INVOICE_IDS_JSON="$(newline_list_to_json_array "$delete_invoice_ids_raw")"
    if [ "$had_blockers" -eq 1 ]; then
        return 1
    fi
    return 0
}

run_reset_db_cleanup() {
    local stripe_in_list invoice_in_list sql query_status where_clause=""
    stripe_in_list="$(json_array_to_sql_in_list "$RESET_STRIPE_CLEARED_IDS_JSON")"
    invoice_in_list="$(json_array_to_sql_in_list "$RESET_DB_DELETE_INVOICE_IDS_JSON")"

    if [ -n "$stripe_in_list" ]; then
        where_clause="stripe_invoice_id IN ($stripe_in_list)"
    fi
    if [ -n "$invoice_in_list" ]; then
        if [ -n "$where_clause" ]; then
            where_clause="${where_clause} OR id::text IN ($invoice_in_list)"
        else
            where_clause="id::text IN ($invoice_in_list)"
        fi
    fi
    if [ -z "$where_clause" ]; then
        return 0
    fi

    local month_bounds month_start month_end
    month_bounds="$(reset_month_bounds "$(reset_month_value)")"
    month_start="$(printf '%s\n' "$month_bounds" | sed -n '1p')"
    month_end="$(printf '%s\n' "$month_bounds" | sed -n '2p')"

    sql="DELETE FROM invoices WHERE customer_id = '$CONFIRM_TEST_TENANT_ID'::uuid AND period_start >= DATE '$month_start' AND period_start < DATE '$month_end' AND (${where_clause}) /* stage4_reset_delete_invoices */"
    if run_rehearsal_db_query "$sql"; then
        return 0
    fi
    query_status=$?
    reset_set_db_query_failure "reset_db_cleanup" "$query_status"
    return 1
}

run_reset_flow() {
    if ! run_reset_customer_lookup; then
        return 1
    fi
    if ! run_reset_invoice_rows_query; then
        return 1
    fi

    if [ "$(json_array_length "$RESET_DB_INVOICE_ROWS_JSON")" -le 0 ]; then
        set_reset_completed_summary "Reset path completed: no invoice rows found for the target month."
        return 0
    fi

    local stripe_cleanup_status=0
    if run_reset_stripe_cleanup; then
        stripe_cleanup_status=0
    else
        stripe_cleanup_status=$?
    fi
    if ! run_reset_db_cleanup; then
        return 1
    fi
    if [ "$stripe_cleanup_status" -ne 0 ]; then
        if [ -n "$RESET_STRIPE_BLOCKED_CLASSIFICATION" ]; then
            set_reset_blocked_summary "$RESET_STRIPE_BLOCKED_CLASSIFICATION" "$RESET_STRIPE_BLOCKED_DETAIL"
        fi
        return 1
    fi

    local reset_detail
    reset_detail="Reset path completed: Stripe and DB invoice cleanup succeeded."
    if [ "$RESET_PAID_DB_ONLY_CLEANUP" -eq 1 ]; then
        reset_detail="${reset_detail} paid Stripe invoice(s); paid Stripe invoices were left unchanged while local DB rows were reset."
    fi
    if [ "$RESET_LOCAL_ONLY_DB_CLEANUP" -eq 1 ]; then
        reset_detail="${reset_detail} Local invoice row(s) without stripe_invoice_id were cleaned up in DB only."
    fi
    set_reset_completed_summary "$reset_detail"
    return 0
}
