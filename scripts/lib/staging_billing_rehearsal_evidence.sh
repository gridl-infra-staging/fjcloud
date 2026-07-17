#!/usr/bin/env bash
# Evidence convergence helpers for staging billing rehearsal.
# shellcheck source=staging_billing_rehearsal_cross_check.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/staging_billing_rehearsal_cross_check.sh"
# Retry an evidence check until it succeeds, reaches a terminal failure, or exhausts the configured attempt budget.
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
    local prefix="$1" query_label="$2" query_status="$3"
    EVIDENCE_LAST_CLASSIFICATION="${prefix}_query_failed"
    if [ "$query_status" -eq 124 ] || [ "$query_status" -eq 20 ]; then
        EVIDENCE_LAST_DETAIL="${query_label} query timed out."
    elif [ "$query_status" -eq 21 ]; then
        EVIDENCE_LAST_DETAIL="${query_label} query could not connect to Postgres."
    elif [ "$query_status" -eq 30 ]; then
        EVIDENCE_LAST_DETAIL="${query_label} query has no database URL."
    else
        EVIDENCE_LAST_DETAIL="${query_label} query failed; raw query output suppressed to avoid exposing billing/customer data."
    fi
    EVIDENCE_TERMINAL_FAILURE=1
}
resolve_created_invoice_uuid_in_list() {
    local ids_json="$1"
    python3 - "$ids_json" <<'PY'
import json
import re
import sys
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
try:
    values = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(3)
if not isinstance(values, list):
    raise SystemExit(3)
sql_literals = []
seen = set()
for value in values:
    invoice_id = str(value).strip()
    if not invoice_id:
        continue
    if not UUID_RE.fullmatch(invoice_id):
        raise SystemExit(4)
    # UUID casts avoid raw text interpolation into the SQL predicate.
    normalized = invoice_id.lower()
    if normalized in seen:
        continue
    seen.add(normalized)
    sql_literals.append(f"'{normalized}'::uuid")
if not sql_literals:
    raise SystemExit(2)
print(",".join(sql_literals))
PY
}
set_created_invoice_ids_failure() {
    local prefix="$1" query_label="$2" id_status="$3"
    if [ "$id_status" -eq 2 ]; then
        EVIDENCE_LAST_CLASSIFICATION="${prefix}_invoice_ids_missing"
        EVIDENCE_LAST_DETAIL="No created invoice IDs are available for ${query_label} evidence."
    else
        EVIDENCE_LAST_CLASSIFICATION="${prefix}_invoice_ids_invalid"
        EVIDENCE_LAST_DETAIL="Created invoice IDs must be a JSON array of UUIDs."
    fi
    EVIDENCE_TERMINAL_FAILURE=1
}
run_invoice_rows_query_once() {
    local in_list sql query_status
    if ! in_list="$(resolve_created_invoice_uuid_in_list "$CREATED_INVOICE_IDS_JSON")"; then
        set_created_invoice_ids_failure "invoice_rows" "invoice row" "$?"
        return 1
    fi
    sql="SELECT i.id::text || '|' || COALESCE(i.stripe_invoice_id,'') || '|' || COALESCE(i.hosted_invoice_url,'') || '|' || COALESCE(to_char(i.paid_at AT TIME ZONE 'utc','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'') || '|' || COALESCE(c.email,'') FROM invoices i JOIN customers c ON c.id = i.customer_id WHERE i.id IN (${in_list}) /* stage3_invoice_rows */"
    run_rehearsal_db_query "$sql" && return 0
    query_status=$?
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
    while len(parts) < 5:
        parts.append("")
    row = {
        "invoice_id": parts[0].strip(),
        "stripe_invoice_id": parts[1].strip(),
        "hosted_invoice_url": parts[2].strip(),
        "paid_at": parts[3].strip(),
        "email": parts[4].strip(),
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
    if (not row.get("stripe_invoice_id")) or (not row.get("hosted_invoice_url")) or (not row.get("paid_at")) or (not row.get("email")):
        bad.append(rid)
if bad:
    print(json.dumps({
        "ready": False,
        "classification": "invoice_rows_missing_required_fields",
        "detail": "invoice rows missing stripe_invoice_id, hosted_invoice_url, paid_at, or email for: " + ", ".join(bad),
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
stage3_transition_invoice_ids_json() {
    python3 - "$CREATED_INVOICE_IDS_JSON" <<'PY' || true
import json
import sys
required_ids = json.loads(sys.argv[1])
first_id = required_ids[0] if len(required_ids) >= 1 else ""
second_id = required_ids[1] if len(required_ids) >= 2 else ""
print(json.dumps({
    "failed": first_id,
    "suspended": second_id,
    "recovered": first_id,
}))
PY
}
set_invoice_rows_payload() {
    local eval_json="$1"
    local transition_invoice_ids_json
    EVIDENCE_LAST_CLASSIFICATION="$(validation_json_get_field "$eval_json" "classification")"
    EVIDENCE_LAST_DETAIL="$(validation_json_get_field "$eval_json" "detail")"
    INVOICE_ROWS_JSON="$(extract_json_array_field "$eval_json" "rows")"
    transition_invoice_ids_json="$(stage3_transition_invoice_ids_json)"
    INVOICE_ROWS_PAYLOAD="$(python3 - "$INVOICE_ROWS_JSON" "$CREATED_INVOICE_IDS_JSON" "$transition_invoice_ids_json" <<'PY' || true
import json
import sys
rows = json.loads(sys.argv[1])
required_ids = json.loads(sys.argv[2])
transition_invoice_ids = json.loads(sys.argv[3])
sanitized_rows = []
for row in rows:
    if not isinstance(row, dict):
        continue
    sanitized_row = {k: v for k, v in row.items() if k != "email"}
    sanitized_row["has_hosted_invoice_url"] = bool(row.get("hosted_invoice_url"))
    sanitized_rows.append(sanitized_row)
print(json.dumps({
    "rows": sanitized_rows,
    "required_invoice_ids": required_ids,
    "transition_invoice_ids": transition_invoice_ids,
}))
PY
)"
}
check_invoice_rows_evidence_once() {
    local eval_json ready
    run_invoice_rows_query_once || return 1
    eval_json="$(invoice_rows_eval_json)"
    ready="$(validation_json_get_field "$eval_json" "ready")"
    set_invoice_rows_payload "$eval_json"
    [ "$ready" = "true" ]
}
run_webhook_query_once() {
    local in_list sql query_status
    if ! in_list="$(resolve_created_invoice_uuid_in_list "$CREATED_INVOICE_IDS_JSON")"; then
        set_created_invoice_ids_failure "webhook" "webhook" "$?"
        return 1
    fi
    sql="SELECT i.id::text || '|' || COALESCE(i.stripe_invoice_id,'') || '|' || COALESCE(to_char(w.processed_at AT TIME ZONE 'utc','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'') FROM invoices i LEFT JOIN webhook_events w ON w.event_type = 'invoice.payment_succeeded' AND w.processed_at IS NOT NULL AND w.payload->'data'->'object'->>'id' = i.stripe_invoice_id WHERE i.id IN (${in_list}) /* stage3_webhook_rows */"
    run_rehearsal_db_query "$sql" && return 0
    query_status=$?
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
    local rows_json transition_invoice_ids_json
    rows_json="$(extract_json_array_field "$eval_json" "rows")"
    EVIDENCE_LAST_CLASSIFICATION="$(validation_json_get_field "$eval_json" "classification")"
    EVIDENCE_LAST_DETAIL="$(validation_json_get_field "$eval_json" "detail")"
    transition_invoice_ids_json="$(stage3_transition_invoice_ids_json)"
    WEBHOOK_PAYLOAD="$(python3 - "$rows_json" "$CREATED_INVOICE_IDS_JSON" "$transition_invoice_ids_json" <<'PY' || true
import json
import sys
rows = json.loads(sys.argv[1])
required_ids = json.loads(sys.argv[2])
transition_invoice_ids = json.loads(sys.argv[3])
print(json.dumps({
    "rows": rows,
    "required_invoice_ids": required_ids,
    "transition_invoice_ids": transition_invoice_ids,
}))
PY
)"
}
check_webhook_evidence_once() {
    local eval_json ready
    run_webhook_query_once || return 1
    eval_json="$(webhook_eval_json)"
    ready="$(validation_json_get_field "$eval_json" "ready")"
    set_webhook_payload "$eval_json"
    [ "$ready" = "true" ]
}
