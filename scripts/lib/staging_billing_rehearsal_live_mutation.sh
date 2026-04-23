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
    python3 - "$HTTP_RESPONSE_BODY" "$HTTP_RESPONSE_CODE" "${CREATED_INVOICE_IDS_JSON:-[]}" <<'PY' || true
import json
import sys

body = sys.argv[1]
code = sys.argv[2]
invoice_ids = json.loads(sys.argv[3]) if len(sys.argv) > 3 else []
payload = {"http_status": code, "invoice_ids": invoice_ids}
try:
    payload["response"] = json.loads(body)
except Exception:
    payload["response_raw"] = body
print(json.dumps(payload))
PY
}

capture_billing_run_attempt() {
    local billing_url created_count request_status

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

    CREATED_INVOICE_IDS_JSON='[]'
    BILLING_RUN_PAYLOAD="$(build_billing_run_payload)"
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        set_billing_run_failure \
            "billing_run_http_error" \
            "POST /admin/billing/run returned HTTP ${HTTP_RESPONSE_CODE}." \
            "$BILLING_RUN_PAYLOAD"
        return 1
    fi

    if ! is_valid_json "$HTTP_RESPONSE_BODY"; then
        set_billing_run_failure \
            "billing_run_response_invalid" \
            "POST /admin/billing/run returned invalid JSON." \
            "$BILLING_RUN_PAYLOAD"
        return 1
    fi

    CREATED_INVOICE_IDS_JSON="$(extract_created_invoice_ids_json "$HTTP_RESPONSE_BODY")"
    BILLING_RUN_PAYLOAD="$(build_billing_run_payload)"
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
        INVOICE_EMAIL_DETAIL="Invoice-ready email evidence converged in Mailpit."
        return 0
    fi

    set_convergence_failure "INVOICE_EMAIL_RESULT" "INVOICE_EMAIL_CLASSIFICATION" "INVOICE_EMAIL_DETAIL"
    return 1
}

run_live_mutation_attempt() {
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
    SUMMARY_DETAIL="Live billing mutation completed with DB, webhook, and email evidence."
    return 0
}
