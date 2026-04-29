#!/usr/bin/env bash
# Evidence convergence helpers for staging billing rehearsal.

# TODO: Document run_bounded_convergence.
# TODO: Document run_bounded_convergence.
# TODO: Document run_bounded_convergence.
# TODO: Document run_bounded_convergence.
run_bounded_convergence() {
    local check_fn="$1"
    local max_attempts="${REHEARSAL_EVIDENCE_MAX_ATTEMPTS:-15}"
    local sleep_sec="${REHEARSAL_EVIDENCE_SLEEP_SEC:-1}"
    local attempt=1

    while [ "$attempt" -le "$max_attempts" ]; do
        EVIDENCE_ATTEMPTS_USED="$attempt"
        EVIDENCE_TERMINAL_FAILURE=0
        if "$check_fn"; then
            return 0
        fi
        if [ "$EVIDENCE_TERMINAL_FAILURE" -eq 1 ]; then
            return 1
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            sleep "$sleep_sec"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

set_db_query_failure() {
    local prefix="$1"
    local query_label="$2"
    local query_status="$3"

    EVIDENCE_LAST_CLASSIFICATION="${prefix}_query_failed"
    if [ "$query_status" -eq 124 ] || [ "$query_status" -eq 20 ]; then
        EVIDENCE_LAST_DETAIL="${query_label} query timed out."
    elif [ "$query_status" -eq 21 ]; then
        EVIDENCE_LAST_DETAIL="${query_label} query could not connect to Postgres."
    elif [ "$query_status" -eq 30 ]; then
        EVIDENCE_LAST_DETAIL="${query_label} query has no database URL."
    else
        EVIDENCE_LAST_DETAIL="${query_label} query failed: $REHEARSAL_QUERY_OUTPUT"
    fi
    EVIDENCE_TERMINAL_FAILURE=1
}

run_invoice_rows_query_once() {
    local in_list sql query_status

    in_list="$(json_array_to_sql_in_list "$CREATED_INVOICE_IDS_JSON")"
    if [ -z "$in_list" ]; then
        EVIDENCE_LAST_CLASSIFICATION="invoice_rows_missing_required_fields"
        EVIDENCE_LAST_DETAIL="No created invoice IDs are available for invoice row evidence."
        EVIDENCE_TERMINAL_FAILURE=1
        return 1
    fi

    sql="SELECT i.id::text || '|' || COALESCE(i.stripe_invoice_id,'') || '|' || COALESCE(to_char(i.paid_at AT TIME ZONE 'utc','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'') || '|' || COALESCE(c.email,'') FROM invoices i JOIN customers c ON c.id = i.customer_id WHERE i.id::text IN (${in_list}) /* stage3_invoice_rows */"
    if run_rehearsal_db_query "$sql"; then
        return 0
    else
        query_status=$?
    fi

    set_db_query_failure "invoice_rows" "Invoice row" "$query_status"
    return 1
}

invoice_rows_eval_json() {
    python3 - "$REHEARSAL_QUERY_OUTPUT" "$CREATED_INVOICE_IDS_JSON" <<'PY' || true
import json
import sys

raw = sys.argv[1]
required_ids = json.loads(sys.argv[2])
rows = []
by_id = {}
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    parts = line.split("|")
    while len(parts) < 4:
        parts.append("")
    row = {
        "invoice_id": parts[0].strip(),
        "stripe_invoice_id": parts[1].strip(),
        "paid_at": parts[2].strip(),
        "email": parts[3].strip(),
    }
    rows.append(row)
    if row["invoice_id"]:
        by_id[row["invoice_id"]] = row

missing = [rid for rid in required_ids if rid not in by_id]
if missing:
    print(json.dumps({
        "ready": False,
        "classification": "invoice_rows_not_ready",
        "detail": "invoice rows missing for: " + ", ".join(missing),
        "rows": rows,
    }))
    raise SystemExit(0)

bad = []
for rid in required_ids:
    row = by_id[rid]
    if (not row.get("stripe_invoice_id")) or (not row.get("paid_at")) or (not row.get("email")):
        bad.append(rid)
if bad:
    print(json.dumps({
        "ready": False,
        "classification": "invoice_rows_missing_required_fields",
        "detail": "invoice rows missing stripe_invoice_id, paid_at, or email for: " + ", ".join(bad),
        "rows": rows,
    }))
    raise SystemExit(0)

print(json.dumps({
    "ready": True,
    "classification": "invoice_rows_ready",
    "detail": "invoice row evidence converged",
    "rows": rows,
}))
PY
}

set_invoice_rows_payload() {
    local eval_json="$1"
    EVIDENCE_LAST_CLASSIFICATION="$(validation_json_get_field "$eval_json" "classification")"
    EVIDENCE_LAST_DETAIL="$(validation_json_get_field "$eval_json" "detail")"
    INVOICE_ROWS_JSON="$(extract_json_array_field "$eval_json" "rows")"
    INVOICE_ROWS_PAYLOAD="$(python3 - "$INVOICE_ROWS_JSON" "$CREATED_INVOICE_IDS_JSON" <<'PY' || true
import json
import sys
rows = json.loads(sys.argv[1])
required_ids = json.loads(sys.argv[2])
print(json.dumps({"rows": rows, "required_invoice_ids": required_ids}))
PY
)"
}

check_invoice_rows_evidence_once() {
    local eval_json ready

    if ! run_invoice_rows_query_once; then
        return 1
    fi

    eval_json="$(invoice_rows_eval_json)"
    ready="$(validation_json_get_field "$eval_json" "ready")"
    set_invoice_rows_payload "$eval_json"

    if [ "$ready" = "true" ]; then
        return 0
    fi
    return 1
}

run_webhook_query_once() {
    local in_list sql query_status

    in_list="$(json_array_to_sql_in_list "$CREATED_INVOICE_IDS_JSON")"
    if [ -z "$in_list" ]; then
        EVIDENCE_LAST_CLASSIFICATION="webhook_not_ready"
        EVIDENCE_LAST_DETAIL="No created invoice IDs are available for webhook evidence."
        EVIDENCE_TERMINAL_FAILURE=1
        return 1
    fi

    sql="SELECT i.id::text || '|' || COALESCE(i.stripe_invoice_id,'') || '|' || COALESCE(to_char(w.processed_at AT TIME ZONE 'utc','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'') FROM invoices i LEFT JOIN webhook_events w ON w.event_type = 'invoice.payment_succeeded' AND w.processed_at IS NOT NULL AND w.payload->'data'->'object'->>'id' = i.stripe_invoice_id WHERE i.id::text IN (${in_list}) /* stage3_webhook_rows */"
    if run_rehearsal_db_query "$sql"; then
        return 0
    else
        query_status=$?
    fi

    set_db_query_failure "webhook" "Webhook" "$query_status"
    return 1
}

webhook_eval_json() {
    python3 - "$REHEARSAL_QUERY_OUTPUT" "$CREATED_INVOICE_IDS_JSON" <<'PY' || true
import json
import sys

raw = sys.argv[1]
required_ids = json.loads(sys.argv[2])
rows = []
by_id = {}
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    parts = line.split("|")
    while len(parts) < 3:
        parts.append("")
    row = {
        "invoice_id": parts[0].strip(),
        "stripe_invoice_id": parts[1].strip(),
        "processed_at": parts[2].strip(),
    }
    rows.append(row)
    if row["invoice_id"]:
        by_id[row["invoice_id"]] = row

missing = [rid for rid in required_ids if rid not in by_id]
if missing:
    print(json.dumps({
        "ready": False,
        "classification": "webhook_not_ready",
        "detail": "webhook rows missing for: " + ", ".join(missing),
        "rows": rows,
    }))
    raise SystemExit(0)

unprocessed = []
for rid in required_ids:
    row = by_id[rid]
    if not row.get("processed_at"):
        unprocessed.append(rid)
if unprocessed:
    print(json.dumps({
        "ready": False,
        "classification": "webhook_not_processed",
        "detail": "invoice.payment_succeeded not processed for: " + ", ".join(unprocessed),
        "rows": rows,
    }))
    raise SystemExit(0)

print(json.dumps({
    "ready": True,
    "classification": "webhook_ready",
    "detail": "webhook evidence converged",
    "rows": rows,
}))
PY
}

set_webhook_payload() {
    local eval_json="$1"
    local rows_json

    rows_json="$(extract_json_array_field "$eval_json" "rows")"
    EVIDENCE_LAST_CLASSIFICATION="$(validation_json_get_field "$eval_json" "classification")"
    EVIDENCE_LAST_DETAIL="$(validation_json_get_field "$eval_json" "detail")"
    WEBHOOK_PAYLOAD="$(python3 - "$rows_json" "$CREATED_INVOICE_IDS_JSON" <<'PY' || true
import json
import sys
rows = json.loads(sys.argv[1])
required_ids = json.loads(sys.argv[2])
print(json.dumps({"rows": rows, "required_invoice_ids": required_ids}))
PY
)"
}

check_webhook_evidence_once() {
    local eval_json ready

    if ! run_webhook_query_once; then
        return 1
    fi

    eval_json="$(webhook_eval_json)"
    ready="$(validation_json_get_field "$eval_json" "ready")"
    set_webhook_payload "$eval_json"

    if [ "$ready" = "true" ]; then
        return 0
    fi
    return 1
}

run_cross_check_query_to_artifact() {
    local artifact_label="$1"
    local artifact_path="$2"
    local sql="$3"
    local query_status

    if run_rehearsal_db_query "$sql"; then
        :
    else
        query_status=$?
        set_db_query_failure "$artifact_label" "$artifact_label" "$query_status"
        return 1
    fi

    if ! write_json_artifact_file "$artifact_path" "$REHEARSAL_QUERY_OUTPUT"; then
        EVIDENCE_LAST_CLASSIFICATION="${artifact_label}_invalid_json"
        EVIDENCE_LAST_DETAIL="${artifact_label} query returned invalid JSON payload."
        EVIDENCE_TERMINAL_FAILURE=1
        return 1
    fi
    return 0
}
build_stage1_invoice_db_row_sql() {
    local invoice_id="$1"
    printf "SELECT COALESCE((SELECT row_to_json(invoice_row)::text FROM (SELECT * FROM invoices WHERE id = '%s'::uuid LIMIT 1) invoice_row), 'null') /* stage1_invoice_db_row */" "$invoice_id"
}
build_stage1_invoice_line_items_sql() {
    local invoice_id="$1"
    printf "SELECT COALESCE((SELECT json_agg(line_row ORDER BY line_row.id)::text FROM (SELECT * FROM invoice_line_items WHERE invoice_id = '%s'::uuid) line_row), '[]') /* stage1_invoice_line_items */" "$invoice_id"
}
build_stage1_customer_billing_context_sql() {
    local invoice_id="$1"
    printf "SELECT COALESCE((SELECT row_to_json(customer_row)::text FROM (SELECT c.id, c.email, c.billing_plan, c.object_storage_egress_carryforward_cents FROM customers c JOIN invoices i ON i.customer_id = c.id WHERE i.id = '%s'::uuid LIMIT 1) customer_row), 'null') /* stage1_customer_billing_context */" "$invoice_id"
}
build_stage1_rate_card_selection_sql() {
    local invoice_id="$1"
    printf "WITH invoice_ctx AS (SELECT id, customer_id, period_start, period_end, created_at, paid_at, created_at AS selection_timestamp, row_to_json(i)::jsonb AS invoice_payload FROM invoices i WHERE id = '%s'::uuid LIMIT 1), effective_card AS (SELECT rc.* FROM rate_cards rc JOIN invoice_ctx i ON rc.effective_from <= i.selection_timestamp AND (rc.effective_until IS NULL OR rc.effective_until > i.selection_timestamp) ORDER BY rc.effective_from DESC LIMIT 1), active_card AS (SELECT rc.* FROM rate_cards rc WHERE rc.effective_until IS NULL ORDER BY rc.effective_from DESC LIMIT 1), matching_override AS (SELECT cro.* FROM customer_rate_overrides cro JOIN invoice_ctx i ON i.customer_id = cro.customer_id JOIN effective_card ec ON ec.id = cro.rate_card_id LIMIT 1) SELECT json_build_object('selection_basis','invoice_created_at','captured_at',to_char(NOW() AT TIME ZONE 'utc','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'invoice_created_at',(SELECT invoice_payload->>'created_at' FROM invoice_ctx),'invoice_paid_at',(SELECT invoice_payload->>'paid_at' FROM invoice_ctx),'invoice_selection_timestamp',(SELECT invoice_payload->>'created_at' FROM invoice_ctx),'invoice_window',(SELECT row_to_json(window_row) FROM (SELECT period_start, period_end FROM invoice_ctx) window_row),'effective_rate_card',(SELECT row_to_json(ec) FROM effective_card ec),'override_exists',EXISTS(SELECT 1 FROM matching_override),'active_rate_card_when_different',(SELECT CASE WHEN active_card.id IS NOT NULL AND effective_card.id IS NOT NULL AND active_card.id <> effective_card.id THEN row_to_json(active_card) ELSE NULL END FROM active_card CROSS JOIN effective_card))::text /* stage1_rate_card_selection */" "$invoice_id"
}
build_stage1_customer_rate_override_sql() {
    printf "SELECT 'null'::text /* stage1_customer_rate_override */"
}
build_stage1_replay_usage_daily_cte_sql() {
    local invoice_id="$1"
    printf "WITH invoice_ctx AS (SELECT customer_id, period_start, period_end, created_at FROM invoices WHERE id = '%s'::uuid LIMIT 1), replay_usage_daily AS (SELECT ud.* FROM usage_daily ud JOIN invoice_ctx i ON i.customer_id = ud.customer_id WHERE ud.date >= i.period_start AND ud.date <= i.period_end AND ud.aggregated_at <= i.created_at)" "$invoice_id"
}
build_stage1_usage_daily_replay_rows_sql() {
    local invoice_id="$1"
    printf "%s SELECT COALESCE((SELECT json_agg(usage_row ORDER BY usage_row.date, usage_row.region)::text FROM replay_usage_daily usage_row), '[]') /* stage1_usage_daily_replay_rows */" "$(build_stage1_replay_usage_daily_cte_sql "$invoice_id")"
}
build_stage1_usage_records_provenance_sql() {
    local invoice_id="$1"
    printf "%s SELECT COALESCE((SELECT json_agg(record_row ORDER BY record_row.recorded_at, record_row.id)::text FROM (SELECT ur.* FROM usage_records ur JOIN replay_usage_daily ud ON ud.customer_id = ur.customer_id AND ud.region = ur.region AND (ur.recorded_at AT TIME ZONE 'utc')::date = ud.date AND ur.recorded_at <= ud.aggregated_at) record_row), '[]') /* stage1_usage_records_provenance */" "$(build_stage1_replay_usage_daily_cte_sql "$invoice_id")"
}
is_invoice_row_payload_present() {
    local json_payload="$1"
    python3 - "$json_payload" <<'PY' || true
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    print("false")
    raise SystemExit(0)
print("true" if isinstance(payload, dict) and payload.get("id") else "false")
PY
}
is_effective_rate_card_present() {
    local json_payload="$1"
    python3 - "$json_payload" <<'PY' || true
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    print("false")
    raise SystemExit(0)
effective = payload.get("effective_rate_card") if isinstance(payload, dict) else None
print("true" if isinstance(effective, dict) and effective.get("id") else "false")
PY
}
stage1_override_exists_from_selection_payload() {
    local json_payload="$1"
    python3 - "$json_payload" <<'PY' || true
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    print("invalid")
    raise SystemExit(0)
if not isinstance(payload, dict):
    print("false")
    raise SystemExit(0)
value = payload.get("override_exists")
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print("false")
PY
}
capture_billing_cross_check_inputs() {
    local invoice_id="$1"
    local bundle_dir="$2"
    local invoice_db_row_path invoice_line_items_path customer_context_path
    local rate_card_selection_path customer_rate_override_path
    local usage_daily_replay_path usage_records_provenance_path
    invoice_db_row_path="$bundle_dir/invoice_db_row.json"
    invoice_line_items_path="$bundle_dir/invoice_line_items.json"
    customer_context_path="$bundle_dir/customer_billing_context.json"
    rate_card_selection_path="$bundle_dir/rate_card_selection.json"
    customer_rate_override_path="$bundle_dir/customer_rate_override.json"
    usage_daily_replay_path="$bundle_dir/usage_daily_replay_rows.json"
    usage_records_provenance_path="$bundle_dir/usage_records_provenance.json"

    mkdir -p "$bundle_dir"
    chmod 700 "$bundle_dir"

    run_cross_check_query_to_artifact \
        "invoice_db_row" \
        "$invoice_db_row_path" \
        "$(build_stage1_invoice_db_row_sql "$invoice_id")" || return 1
    if [ "$(is_invoice_row_payload_present "$(cat "$invoice_db_row_path")")" != "true" ]; then
        EVIDENCE_LAST_CLASSIFICATION="invoice_db_row_missing"
        EVIDENCE_LAST_DETAIL="No invoices row exists for invoice_id=${invoice_id}."
        EVIDENCE_TERMINAL_FAILURE=1
        return 1
    fi

    run_cross_check_query_to_artifact \
        "invoice_line_items" \
        "$invoice_line_items_path" \
        "$(build_stage1_invoice_line_items_sql "$invoice_id")" || return 1

    run_cross_check_query_to_artifact \
        "customer_billing_context" \
        "$customer_context_path" \
        "$(build_stage1_customer_billing_context_sql "$invoice_id")" || return 1

    run_cross_check_query_to_artifact \
        "rate_card_selection" \
        "$rate_card_selection_path" \
        "$(build_stage1_rate_card_selection_sql "$invoice_id")" || return 1
    if [ "$(is_effective_rate_card_present "$(cat "$rate_card_selection_path")")" != "true" ]; then
        EVIDENCE_LAST_CLASSIFICATION="rate_card_selection_missing_effective"
        EVIDENCE_LAST_DETAIL="Missing invoice-window effective rate card; refusing fallback to current active pricing."
        EVIDENCE_TERMINAL_FAILURE=1
        return 1
    fi

    run_cross_check_query_to_artifact \
        "customer_rate_override" \
        "$customer_rate_override_path" \
        "$(build_stage1_customer_rate_override_sql "$invoice_id")" || return 1
    local selection_override_exists
    selection_override_exists="$(stage1_override_exists_from_selection_payload "$(cat "$rate_card_selection_path")")"
    if [ "$selection_override_exists" = "invalid" ]; then
        EVIDENCE_LAST_CLASSIFICATION="rate_card_selection_invalid_json"
        EVIDENCE_LAST_DETAIL="rate_card_selection artifact is invalid JSON."
        EVIDENCE_TERMINAL_FAILURE=1
        return 1
    fi
    if [ "$selection_override_exists" = "true" ] && [ "$(cat "$customer_rate_override_path")" = "null" ]; then
        EVIDENCE_LAST_CLASSIFICATION="customer_rate_override_missing_historical_proof"
        EVIDENCE_LAST_DETAIL="Cannot prove historical override payload at invoice-created timestamp because customer_rate_overrides is mutable via in-place upsert."
        EVIDENCE_TERMINAL_FAILURE=1
        return 1
    fi

    run_cross_check_query_to_artifact \
        "usage_daily_replay_rows" \
        "$usage_daily_replay_path" \
        "$(build_stage1_usage_daily_replay_rows_sql "$invoice_id")" || return 1

    run_cross_check_query_to_artifact \
        "usage_records_provenance" \
        "$usage_records_provenance_path" \
        "$(build_stage1_usage_records_provenance_sql "$invoice_id")" || return 1
    EVIDENCE_LAST_CLASSIFICATION="billing_cross_check_bundle_ready"
    EVIDENCE_LAST_DETAIL="Stage 1 billing cross-check artifacts captured."
    EVIDENCE_TERMINAL_FAILURE=0
    return 0
}
STAGING_BILLING_REHEARSAL_EVIDENCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=staging_billing_rehearsal_email_evidence.sh
source "$STAGING_BILLING_REHEARSAL_EVIDENCE_LIB_DIR/staging_billing_rehearsal_email_evidence.sh"
