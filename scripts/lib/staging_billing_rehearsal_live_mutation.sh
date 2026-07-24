#!/usr/bin/env bash
# Live mutation execution helpers for staging billing rehearsal.

set_attempt_failure() {
    local classification="$1"
    local detail="$2"
    STEP_ATTEMPT_RESULT="failed"
    STEP_ATTEMPT_CLASSIFICATION="$classification"
    STEP_ATTEMPT_DETAIL="$detail"
    SUMMARY_RESULT="failed"
    SUMMARY_CLASSIFICATION="$classification"
    SUMMARY_DETAIL="$detail"
}

set_billing_run_failure() {
    local classification="$1"
    local detail="$2"
    local payload_json="${3:-}"
    if [ -z "$payload_json" ]; then
        payload_json='{}'
    fi
    BILLING_RUN_RESULT="failed"
    BILLING_RUN_CLASSIFICATION="$classification"
    BILLING_RUN_DETAIL="$detail"
    BILLING_RUN_PAYLOAD="$payload_json"
    set_attempt_failure "$classification" "$detail"
}

set_convergence_failure() {
    local result_var="$1"
    local class_var="$2"
    local detail_var="$3"
    local detail

    detail="${EVIDENCE_LAST_DETAIL} (attempts=${EVIDENCE_ATTEMPTS_USED})."
    printf -v "$result_var" "failed"
    printf -v "$class_var" "%s" "$EVIDENCE_LAST_CLASSIFICATION"
    printf -v "$detail_var" "%s" "$detail"
    set_attempt_failure "$EVIDENCE_LAST_CLASSIFICATION" "$detail"
}

build_billing_run_payload() {
    local body_file invoice_ids_file
    body_file="$(mktemp)"
    invoice_ids_file="$(mktemp)"
    printf '%s' "$HTTP_RESPONSE_BODY" > "$body_file"
    printf '%s' "${CREATED_INVOICE_IDS_JSON:-[]}" > "$invoice_ids_file"
    python3 - "$body_file" "$HTTP_RESPONSE_CODE" "$invoice_ids_file" <<'PY' || true
import json
import pathlib
import sys

body = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
code = sys.argv[2]
invoice_ids = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")) if len(sys.argv) > 3 else []
payload = {"http_status": code, "invoice_ids": invoice_ids}
try:
    payload["response"] = json.loads(body)
except Exception:
    payload["response_raw"] = body
print(json.dumps(payload))
PY
    rm -f "$body_file" "$invoice_ids_file"
}

# TODO: Document capture_billing_run_attempt.
capture_billing_run_attempt() {
    local billing_url created_count request_status http_body_file

    billing_url="${STAGING_API_URL%/}/admin/billing/run"
    request_status=0
    if capture_http_json_response -X POST "$billing_url" \
        -H "Content-Type: application/json" \
        -H "x-admin-key: ${ADMIN_KEY}" \
        -d "{\"month\":\"${BILLING_MONTH}\"}"; then
        :
    else
        request_status=$?
        if [ "$request_status" -eq 124 ] || [ "$request_status" -eq 28 ]; then
            set_billing_run_failure \
                "billing_run_request_timed_out" \
                "POST /admin/billing/run timed out before an HTTP response was captured." \
                '{}'
            return 1
        fi
        set_billing_run_failure \
            "billing_run_request_failed" \
            "POST /admin/billing/run request failed before an HTTP response was captured." \
            '{}'
        return 1
    fi

    http_body_file="$(mktemp)"
    printf '%s' "$HTTP_RESPONSE_BODY" > "$http_body_file"
    CREATED_INVOICE_IDS_JSON='[]'
    BILLING_RUN_PAYLOAD="$(build_billing_run_payload)"
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        rm -f "$http_body_file"
        set_billing_run_failure \
            "billing_run_http_error" \
            "POST /admin/billing/run returned HTTP ${HTTP_RESPONSE_CODE}." \
            "$BILLING_RUN_PAYLOAD"
        return 1
    fi

    if ! python3 - "$http_body_file" <<'PY' >/dev/null 2>&1; then
import json
import pathlib
import sys

json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
PY
        set_billing_run_failure \
            "billing_run_response_invalid" \
            "POST /admin/billing/run returned invalid JSON." \
            "$BILLING_RUN_PAYLOAD"
        rm -f "$http_body_file"
        return 1
    fi

    CREATED_INVOICE_IDS_JSON="$(python3 - "$http_body_file" <<'PY' || true
import json
import pathlib
import sys

try:
    payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    print("[]")
    raise SystemExit(0)

ids = []
for item in payload.get("results", []):
    if not isinstance(item, dict):
        continue
    if item.get("status") != "created":
        continue
    invoice_id = item.get("invoice_id")
    if invoice_id is None:
        continue
    invoice_id = str(invoice_id).strip()
    if invoice_id:
        ids.append(invoice_id)

print(json.dumps(ids))
PY
)"
    BILLING_RUN_PAYLOAD="$(build_billing_run_payload)"
    rm -f "$http_body_file"
    created_count="$(json_array_length "$CREATED_INVOICE_IDS_JSON")"
    if [ "$created_count" -le 0 ]; then
        set_billing_run_failure \
            "billing_run_no_created_invoices" \
            "Batch billing response did not include any created invoice_id values." \
            "$BILLING_RUN_PAYLOAD"
        return 1
    fi

    BILLING_RUN_RESULT="passed"
    BILLING_RUN_CLASSIFICATION="billing_run_succeeded"
    BILLING_RUN_DETAIL="POST /admin/billing/run returned ${created_count} created invoice(s)."
    return 0
}

run_invoice_rows_convergence() {
    if run_bounded_convergence check_invoice_rows_evidence_once; then
        INVOICE_ROWS_RESULT="passed"
        INVOICE_ROWS_CLASSIFICATION="invoice_rows_ready"
        INVOICE_ROWS_DETAIL="Invoice rows converged for all created invoice IDs."
        return 0
    fi

    set_convergence_failure "INVOICE_ROWS_RESULT" "INVOICE_ROWS_CLASSIFICATION" "INVOICE_ROWS_DETAIL"
    return 1
}

run_webhook_convergence() {
    if run_bounded_convergence check_webhook_evidence_once; then
        WEBHOOK_RESULT="passed"
        WEBHOOK_CLASSIFICATION="webhook_ready"
        WEBHOOK_DETAIL="Webhook evidence converged for all created invoice IDs."
        return 0
    fi

    set_convergence_failure "WEBHOOK_RESULT" "WEBHOOK_CLASSIFICATION" "WEBHOOK_DETAIL"
    return 1
}

run_invoice_email_convergence() {
    if run_bounded_convergence check_invoice_email_evidence_once; then
        INVOICE_EMAIL_RESULT="passed"
        INVOICE_EMAIL_CLASSIFICATION="invoice_email_ready"
        INVOICE_EMAIL_DETAIL="$EVIDENCE_LAST_DETAIL"
        return 0
    fi

    set_convergence_failure "INVOICE_EMAIL_RESULT" "INVOICE_EMAIL_CLASSIFICATION" "INVOICE_EMAIL_DETAIL"
    return 1
}

repeat_pass_tenant_label() {
    python3 - "$1" <<'PY' || true
import json
import sys

try:
    tenant_ids = json.loads(sys.argv[1])
except Exception:
    tenant_ids = []
labels = [str(tenant_id).strip() for tenant_id in tenant_ids if str(tenant_id).strip()]
print(", ".join(labels) if labels else "<tenant unavailable>")
PY
}

# Populates the billing-run/step/summary output variables for a same-month
# repeat-pass: we reuse the previously-created rehearsal invoice IDs and skip the
# /admin/billing/run mutation plus all downstream evidence convergence.
set_repeat_pass_outputs() {
    local invoice_ids_json="$1"
    local month="$2"
    local tenant_ids_json="$3"
    local tenant_label payload_json detail count
    tenant_label="$(repeat_pass_tenant_label "$tenant_ids_json")"
    count="$(json_array_length "$invoice_ids_json")"
    payload_json="$(python3 - "$invoice_ids_json" "$tenant_ids_json" "$month" <<'PY' || true
import json
import sys

ids = json.loads(sys.argv[1])
tenant_ids = json.loads(sys.argv[2])
print(json.dumps({
    "month": sys.argv[3],
    "tenants": tenant_ids,
    "invoice_ids": ids,
    "reused_tenant_ids": tenant_ids,
    "reused_invoice_ids": ids,
}))
PY
)"
    detail="Reused ${count} existing same-month invoice(s) for ${month}; tenants: ${tenant_label}."

    CREATED_INVOICE_IDS_JSON="$invoice_ids_json"
    BILLING_RUN_RESULT="passed"
    BILLING_RUN_CLASSIFICATION="billing_run_repeat_pass_existing_same_month_invoice"
    BILLING_RUN_DETAIL="$detail"
    BILLING_RUN_PAYLOAD="$payload_json"
    STEP_ATTEMPT_RESULT="passed"
    STEP_ATTEMPT_CLASSIFICATION="billing_run_repeat_pass_existing_same_month_invoice"
    STEP_ATTEMPT_DETAIL="$detail"
    SUMMARY_RESULT="passed"
    SUMMARY_CLASSIFICATION="billing_run_repeat_pass_existing_same_month_invoice"
    SUMMARY_DETAIL="$detail"
}

set_same_month_lookup_failure() {
    local lookup_status="$1"
    local payload_json detail

    payload_json="$(python3 - "$BILLING_MONTH" "$lookup_status" <<'PY' || true
import json
import sys

print(json.dumps({
    "month": sys.argv[1],
    "query_exit_status": int(sys.argv[2]),
}))
PY
)"
    detail="Same-month invoice lookup failed for ${BILLING_MONTH}; refusing POST /admin/billing/run without proving repeat-pass reuse is unavailable."
    set_billing_run_failure "same_month_invoice_lookup_failed" "$detail" "$payload_json"
}

# Returns 0 when the canonical DB lookup found pre-existing same-month rehearsal
# invoices and the repeat-pass output variables were set. Returns 1 when no rows
# were found, so the caller proceeds to the normal /admin/billing/run mutation
# path. Returns 2 when the lookup failed and the caller must fail closed.
run_repeat_pass_check() {
    local lookup_status invoice_ids_json tenant_ids_json count

    REHEARSAL_QUERY_OUTPUT=""
    run_existing_same_month_invoice_lookup "$BILLING_MONTH" || lookup_status=$?
    if [ "${lookup_status:-0}" -ne 0 ]; then
        set_same_month_lookup_failure "${lookup_status}"
        return 2
    fi

    invoice_ids_json="$(parse_existing_same_month_invoice_ids "$REHEARSAL_QUERY_OUTPUT")"
    tenant_ids_json="$(parse_existing_same_month_invoice_tenant_ids "$REHEARSAL_QUERY_OUTPUT")"
    count="$(json_array_length "$invoice_ids_json")"
    if [ "$count" -le 0 ]; then
        return 1
    fi
    set_repeat_pass_outputs "$invoice_ids_json" "$BILLING_MONTH" "$tenant_ids_json"
    return 0
}

run_live_mutation_attempt() {
    local repeat_status=0

    run_repeat_pass_check || repeat_status=$?
    if [ "$repeat_status" -eq 0 ]; then
        if ! run_invoice_rows_convergence; then
            return 1
        fi
        if ! run_invoice_email_convergence; then
            return 1
        fi
        return 0
    fi
    if [ "$repeat_status" -ne 1 ]; then
        return 1
    fi
    if ! capture_billing_run_attempt; then
        return 1
    fi
    if ! run_invoice_rows_convergence; then
        return 1
    fi
    if ! run_webhook_convergence; then
        return 1
    fi
    if ! run_invoice_email_convergence; then
        return 1
    fi

    STEP_ATTEMPT_RESULT="passed"
    STEP_ATTEMPT_CLASSIFICATION="live_mutation_succeeded"
    STEP_ATTEMPT_DETAIL="Live billing mutation and evidence closure succeeded."
    SUMMARY_RESULT="passed"
    SUMMARY_CLASSIFICATION="rehearsal_completed"
    SUMMARY_DETAIL="Live billing mutation completed with DB, webhook, and invoice-email evidence."
    return 0
}
