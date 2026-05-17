#!/usr/bin/env bash
# Run a live Privacy.com -> Stripe attach -> billing execution using existing owners.
# shellcheck disable=SC1091
set -euo pipefail

LIVE_E2E_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_E2E_REPO_ROOT="$(cd "$LIVE_E2E_SCRIPT_DIR/../.." && pwd)"

# Explicit owner sources required by the stage contract.
source "$LIVE_E2E_REPO_ROOT/scripts/lib/stripe_checks.sh"
source "$LIVE_E2E_REPO_ROOT/scripts/lib/privacy_com_client.sh"
source "$LIVE_E2E_REPO_ROOT/scripts/lib/env.sh"

DRY_RUN="false"
TARGET_ENV=""
BILLING_MONTH="${BILLING_MONTH:-$(date -u +%Y-%m)}"
LIVE_E2E_EVIDENCE_DIR="${LIVE_E2E_EVIDENCE_DIR:-${LIVE_E2E_REPO_ROOT}/docs/runbooks/evidence/privacy_com_contract/live_card_e2e}"
LIVE_E2E_SWEEPER_BIN="${LIVE_E2E_SWEEPER_BIN:-$LIVE_E2E_SCRIPT_DIR/privacy_card_sweeper.sh}"
LIVE_E2E_CONVERGENCE_ATTEMPTS="${LIVE_E2E_CONVERGENCE_ATTEMPTS:-12}"
LIVE_E2E_CONVERGENCE_SLEEP_SECONDS="${LIVE_E2E_CONVERGENCE_SLEEP_SECONDS:-5}"

TOKEN=""
PM_ID=""
INVOICE_IDS_JSON='[]'
INVOICE_CUSTOMERS_JSON='[]'
WEBHOOK_OK="false"
SWEEPER_SUMMARY='{}'
STRIPE_CUTOVER="false"
CLEANUP_CARD_CLOSED="false"
CLEANUP_PM_DETACHED="false"
RUN_CLASSIFICATION="success"
RUN_DIR=""
RUN_LOGS_DIR=""
SUMMARY_PATH=""
SUMMARY_EMITTED="false"

redact_identifier() {
    local value="${1:-}"
    if [ -n "$value" ]; then
        printf '[REDACTED]\n'
        return
    fi
    printf '\n'
}

require_env_var() {
    local var_name="$1"
    if [ -z "${!var_name:-}" ]; then
        fail_with_classification "env_missing" "missing required env: ${var_name}"
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --env=*)
                TARGET_ENV="${1#--env=}"
                if [ "$TARGET_ENV" != "prod" ]; then
                    echo "ERROR: unknown env value: $TARGET_ENV" >&2
                    exit 2
                fi
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            *)
                echo "ERROR: unknown argument: $1" >&2
                exit 2
                ;;
        esac
    done

    if [ -z "$TARGET_ENV" ]; then
        echo "ERROR: missing required argument: --env=prod" >&2
        exit 2
    fi
}

extract_reason_code() {
    local output="$1"
    local reason_line
    reason_line="$(printf '%s\n' "$output" | grep -m1 '^REASON:' || true)"
    if [ -n "$reason_line" ]; then
        _strip_reason_prefix "$reason_line"
        return
    fi
    printf 'gate_check_failed\n'
}

fail_with_classification() {
    local classification="$1"
    local message="$2"
    RUN_CLASSIFICATION="$classification"
    echo "classification=${classification}" >&2
    echo "$message" >&2
    exit 1
}

create_run_id() {
    printf 'fjcloud_live_e2e_evidence_%s_%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

initialize_run_artifacts() {
    mkdir -p "$LIVE_E2E_EVIDENCE_DIR"
    RUN_DIR="$LIVE_E2E_EVIDENCE_DIR/$(create_run_id)"
    mkdir -p "$RUN_DIR"
    RUN_LOGS_DIR="$RUN_DIR/logs"
    mkdir -p "$RUN_LOGS_DIR"
    SUMMARY_PATH="$RUN_DIR/summary.json"
}

validate_billing_month() {
    if ! [[ "$BILLING_MONTH" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        fail_with_classification "billing_month_invalid" "BILLING_MONTH must match YYYY-MM"
    fi
}

run_stripe_gate_check() {
    local fn_name="$1"
    local default_reason="$2"
    local check_output=""
    local check_exit=0
    set +e
    check_output="$( (
        export BACKEND_LIVE_GATE=1
        "$fn_name"
    ) 2>&1)"
    check_exit=$?
    set -e

    if [ "$check_exit" -eq 0 ]; then
        return 0
    fi

    local reason
    reason="$(extract_reason_code "$check_output")"
    if [ -z "$reason" ]; then
        reason="$default_reason"
    fi
    fail_with_classification "$reason" "$check_output"
}

cleanup_resources() {
    local previous_errexit_state="$-"
    set +e

    if [ -n "$TOKEN" ]; then
        if privacy_com_close_card "$TOKEN" >/dev/null 2>&1 && [ "${PRIVACY_CLIENT_EXIT_CLASS:-}" = "ok" ]; then
            CLEANUP_CARD_CLOSED="true"
            TOKEN=""
        else
            echo "cleanup warning: failed to close privacy card" >&2
        fi
    fi

    if [ -n "$PM_ID" ]; then
        local stripe_key
        stripe_key="$(resolve_stripe_secret_key 2>/dev/null || true)"
        if [ -n "$stripe_key" ]; then
            local response=""
            local curl_status=0
            response="$(curl -sS \
                --config <(stripe_curl_user_config "$stripe_key") \
                --max-time 20 \
                --connect-timeout 10 \
                -X POST "https://api.stripe.com/v1/payment_methods/${PM_ID}/detach" \
                -w "\n%{http_code}" 2>/dev/null)" || curl_status=$?
            if [ "$curl_status" -eq 0 ] && [ "$(printf '%s\n' "$response" | tail -1)" = "200" ]; then
                CLEANUP_PM_DETACHED="true"
                PM_ID=""
            else
                echo "cleanup warning: failed to detach payment method" >&2
            fi
        else
            echo "cleanup warning: stripe key unavailable for detach" >&2
        fi
    fi

    if [[ "$previous_errexit_state" == *e* ]]; then
        set -e
    fi
}

run_sweeper() {
    local sweeper_output
    local -a sweeper_args=("$LIVE_E2E_SWEEPER_BIN")
    if [ "$DRY_RUN" = "true" ]; then
        sweeper_args+=("--dry-run")
    fi

    if ! sweeper_output="$(bash "${sweeper_args[@]}" >"$RUN_LOGS_DIR/sweeper.stdout.log" 2>"$RUN_LOGS_DIR/sweeper.stderr.log")"; then
        fail_with_classification "privacy_sweeper_failed" "privacy_card_sweeper.sh exited non-zero"
    fi

    sweeper_output="$(cat "$RUN_LOGS_DIR/sweeper.stdout.log")"
    SWEEPER_SUMMARY="$sweeper_output"
    local sweeper_summary_file="$RUN_DIR/sweeper_summary.json"
    printf '%s\n' "$sweeper_output" > "$sweeper_summary_file"
}

parse_privacy_card_fields() {
    local parsed
    parsed="$(python3 - "$PRIVACY_CLIENT_BODY" <<'PY'
import json
import sys

body = json.loads(sys.argv[1])
token = str(body.get("token", "")).strip()
pan = str(body.get("pan", "")).strip()
cvv = str(body.get("cvv", "")).strip()
exp_month = str(body.get("exp_month", "")).strip().zfill(2)
exp_year = str(body.get("exp_year", "")).strip()
if len(exp_year) >= 2:
    exp_year = exp_year[-2:]
card_exp = f"{exp_month}/{exp_year}" if exp_month and exp_year else ""
print("|".join([token, pan, cvv, card_exp]))
PY
)"

    local token pan cvv card_exp
    IFS='|' read -r token pan cvv card_exp <<< "$parsed"
    if [ -z "$token" ] || [ -z "$pan" ] || [ -z "$cvv" ] || [ -z "$card_exp" ]; then
        fail_with_classification "privacy_card_shape_invalid" "privacy_com_create_card response missing card fields"
    fi
    TOKEN="$token"
    printf '%s|%s|%s\n' "$pan" "$cvv" "$card_exp"
}

create_setup_intent() {
    local stripe_key
    stripe_key="$(resolve_stripe_secret_key)"

    capture_json_response curl -sS \
        --config <(stripe_curl_user_config "$stripe_key") \
        --max-time 20 \
        --connect-timeout 10 \
        -X POST "https://api.stripe.com/v1/setup_intents" \
        -d "customer=${LIVE_E2E_STRIPE_CUSTOMER_ID}" \
        -d "payment_method_types[]=card" \
        -d "usage=off_session"
    persist_step_capture "stripe_setup_intent"

    if [ "${HTTP_RESPONSE_EXIT_STATUS:-0}" -ne 0 ]; then
        fail_with_classification "stripe_setup_intent_request_failed" "Stripe SetupIntent request failed before HTTP response"
    fi
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        fail_with_classification "stripe_setup_intent_http_error" "Stripe SetupIntent returned HTTP ${HTTP_RESPONSE_CODE}"
    fi

    python3 - "$HTTP_RESPONSE_BODY" <<'PY'
import json
import sys

body = json.loads(sys.argv[1])
secret = str(body.get("client_secret", "")).strip()
if not secret:
    raise SystemExit(1)
print(secret)
PY
}

attach_card_via_setup_intent() {
    local client_secret="$1"
    local card_number="$2"
    local card_cvc="$3"
    local card_exp="$4"

    local attach_output=""
    local attach_exit=0
    set +e
    attach_output="$(
        PK_LIVE="$PK_LIVE" \
        CLIENT_SECRET="$client_secret" \
        CARD_NUMBER="$card_number" \
        CARD_EXP="$card_exp" \
        CARD_CVC="$card_cvc" \
        node "$LIVE_E2E_REPO_ROOT/scripts/stripe/attach_card_via_setup_intent.mjs" 2>&1
    )"
    attach_exit=$?
    set -e
    persist_attach_capture "stripe_attach" "$attach_exit" "$attach_output"

    if [ "$attach_exit" -ne 0 ]; then
        fail_with_classification "stripe_attach_failed" "$attach_output"
    fi

    local pm_id
    pm_id="$(python3 - "$attach_output" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
if not payload.get("ok"):
    raise SystemExit(1)
pm_id = str(payload.get("pm_id", "")).strip()
if not pm_id:
    raise SystemExit(1)
print(pm_id)
PY
)"

    PM_ID="$pm_id"
}

persist_privacy_client_capture() {
    # Persist the Privacy.com client's last response from PRIVACY_CLIENT_*
    # globals so failures (notably HTTP 405 max-card-limit) leave a parseable
    # artifact in the run dir instead of only stderr text.
    local capture_name="$1"
    [ -n "${RUN_LOGS_DIR:-}" ] || return 0
    local capture_path="$RUN_LOGS_DIR/${capture_name}.response.json"
    persist_capture_artifact \
        "$capture_path" \
        "privacy" \
        "${PRIVACY_CLIENT_HTTP_CODE:-}" \
        "${PRIVACY_CLIENT_EXIT_CLASS:-}" \
        "${PRIVACY_CLIENT_ERROR_MESSAGE:-}" \
        "${PRIVACY_CLIENT_BODY:-}"
}

persist_capture_artifact() {
    local capture_path="$1"
    local capture_mode="$2"
    local http_code="$3"
    local status_value="$4"
    local error_message="$5"
    local body_raw="$6"
    python3 "$LIVE_E2E_REPO_ROOT/scripts/lib/persist_capture_artifact.py" \
        "$capture_mode" \
        "$http_code" \
        "$status_value" \
        "$error_message" \
        "$body_raw" \
        > "$capture_path"
}

persist_step_capture() {
    # Persist the most recent HTTP response captured via capture_json_response
    # so the run directory is self-contained without a live re-run. Body is
    # embedded as parsed JSON when valid, otherwise as a JSON string, so grep
    # against the file matches the same shape an operator would inspect.
    local capture_name="$1"
    [ -n "${RUN_LOGS_DIR:-}" ] || return 0
    local capture_path="$RUN_LOGS_DIR/${capture_name}.response.json"
    persist_capture_artifact \
        "$capture_path" \
        "step" \
        "${HTTP_RESPONSE_CODE:-}" \
        "${HTTP_RESPONSE_EXIT_STATUS:-}" \
        "" \
        "${HTTP_RESPONSE_BODY:-}"
}

persist_attach_capture() {
    local capture_name="$1"
    local attach_exit_status="$2"
    local attach_output="$3"
    [ -n "${RUN_LOGS_DIR:-}" ] || return 0
    local capture_path="$RUN_LOGS_DIR/${capture_name}.response.json"
    persist_capture_artifact \
        "$capture_path" \
        "attach" \
        "" \
        "$attach_exit_status" \
        "" \
        "$attach_output"
}

run_billing_trigger() {
    capture_json_response admin_call POST "/admin/billing/run" -d "{\"month\":\"$BILLING_MONTH\"}"
    persist_step_capture "billing_trigger"

    if [ "${HTTP_RESPONSE_EXIT_STATUS:-0}" -ne 0 ]; then
        fail_with_classification "billing_run_request_failed" "POST /admin/billing/run failed before HTTP response"
    fi
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        fail_with_classification "billing_run_http_error" "POST /admin/billing/run returned HTTP ${HTTP_RESPONSE_CODE}"
    fi

    local parsed
    parsed="$(python3 - "$HTTP_RESPONSE_BODY" <<'PY'
import json
import sys

body = json.loads(sys.argv[1])
ids = []
customers = []
for item in body.get("results", []):
    invoice_id = item.get("invoice_id")
    customer_id = item.get("customer_id")
    if invoice_id is None or customer_id is None:
        continue
    invoice_id = str(invoice_id).strip()
    customer_id = str(customer_id).strip()
    if not invoice_id or not customer_id:
        continue
    ids.append(invoice_id)
    customers.append({"invoice_id": invoice_id, "customer_id": customer_id})
if not ids:
    raise SystemExit(1)
print(json.dumps(ids, separators=(",", ":")))
print(json.dumps(customers, separators=(",", ":")))
PY
)" || fail_with_classification "billing_run_no_created_invoices" "Batch billing response had no created invoice_id values"

    INVOICE_IDS_JSON="$(printf '%s\n' "$parsed" | sed -n '1p')"
    INVOICE_CUSTOMERS_JSON="$(printf '%s\n' "$parsed" | sed -n '2p')"
}

invoice_is_paid_for_customer() {
    local customer_id="$1"
    local invoice_id="$2"

    capture_json_response admin_call GET "/admin/tenants/${customer_id}/invoices"
    if [ -n "${RUN_LOGS_DIR:-}" ]; then
        LIVE_E2E_POLL_SEQ=$((${LIVE_E2E_POLL_SEQ:-0} + 1))
        persist_step_capture "$(printf 'invoice_poll_%04d_%s' "$LIVE_E2E_POLL_SEQ" "$invoice_id")"
    fi
    if [ "${HTTP_RESPONSE_EXIT_STATUS:-0}" -ne 0 ]; then
        return 2
    fi
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        return 3
    fi

    python3 - "$HTTP_RESPONSE_BODY" "$invoice_id" <<'PY'
import json
import sys

invoices = json.loads(sys.argv[1])
invoice_id = sys.argv[2]
for item in invoices:
    if str(item.get("id", "")).strip() != invoice_id:
        continue
    status = str(item.get("status", "")).strip().lower()
    if status == "paid":
        raise SystemExit(0)
    raise SystemExit(1)
raise SystemExit(1)
PY
}

run_invoice_webhook_convergence() {
    local attempt=1

    # Poll admin invoice read-side status; paid indicates invoice finalize + webhook settled.
    while [ "$attempt" -le "$LIVE_E2E_CONVERGENCE_ATTEMPTS" ]; do
        local all_paid="true"
        while IFS='|' read -r invoice_id customer_id; do
            [ -n "$invoice_id" ] || continue
            [ -n "$customer_id" ] || continue

            set +e
            invoice_is_paid_for_customer "$customer_id" "$invoice_id"
            local invoice_check_rc=$?
            set -e

            if [ "$invoice_check_rc" -eq 0 ]; then
                continue
            fi
            if [ "$invoice_check_rc" -eq 2 ]; then
                fail_with_classification "invoice_poll_transport_failed" "invoice status poll failed before HTTP response"
            fi
            if [ "$invoice_check_rc" -eq 3 ]; then
                fail_with_classification "invoice_poll_http_error" "invoice status poll returned non-200"
            fi

            all_paid="false"
            break
        done < <(python3 - "$INVOICE_CUSTOMERS_JSON" <<'PY'
import json
import sys

pairs = json.loads(sys.argv[1])
for pair in pairs:
    print(f"{pair.get('invoice_id', '')}|{pair.get('customer_id', '')}")
PY
)

        if [ "$all_paid" = "true" ]; then
            WEBHOOK_OK="true"
            return 0
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -le "$LIVE_E2E_CONVERGENCE_ATTEMPTS" ]; then
            sleep "$LIVE_E2E_CONVERGENCE_SLEEP_SECONDS"
        fi
    done

    fail_with_classification "webhook_convergence_timeout" "invoice status did not converge to paid within bounded attempts"
}

emit_summary_json() {
    local redacted_token
    local redacted_pm_id
    redacted_token="$(redact_identifier "$TOKEN")"
    redacted_pm_id="$(redact_identifier "$PM_ID")"
    python3 - "$DRY_RUN" "$TARGET_ENV" "$STRIPE_CUTOVER" "$SWEEPER_SUMMARY" "$redacted_token" "$redacted_pm_id" "$INVOICE_IDS_JSON" "$WEBHOOK_OK" "$CLEANUP_CARD_CLOSED" "$CLEANUP_PM_DETACHED" "$RUN_CLASSIFICATION" "$RUN_DIR" <<'PY'
import json
import sys

summary = {
    "dry_run": sys.argv[1] == "true",
    "env": sys.argv[2],
    "stripe_cutover": sys.argv[3] == "true",
    "sweeper_summary": json.loads(sys.argv[4]),
    "card_token": sys.argv[5],
    "pm_id": sys.argv[6],
    "invoice_ids": json.loads(sys.argv[7]),
    "webhook_ok": sys.argv[8] == "true",
    "cleanup": {
        "card_closed": sys.argv[9] == "true",
        "pm_detached": sys.argv[10] == "true",
    },
    "classification": sys.argv[11],
    "run_dir": sys.argv[12],
}
print(json.dumps(summary, separators=(",", ":")))
PY
}

persist_summary() {
    local summary_json
    summary_json="$(emit_summary_json)"
    printf '%s\n' "$summary_json" | tee "$SUMMARY_PATH"
    SUMMARY_EMITTED="true"
}

main() {
    parse_args "$@"
    initialize_run_artifacts
    trap exit_trap EXIT

    require_env_var "LIVE_E2E_STRIPE_CUSTOMER_ID"
    require_env_var "API_URL"
    require_env_var "ADMIN_KEY"
    require_env_var "PK_LIVE"
    validate_billing_month

    if ! privacy_com_require_env; then
        fail_with_classification "privacy_env_error" "${PRIVACY_CLIENT_ERROR_MESSAGE:-privacy_com_require_env failed}"
    fi

    run_stripe_gate_check "check_stripe_key_present" "stripe_key_bad_prefix"
    run_stripe_gate_check "check_stripe_key_live" "stripe_key_live_check_failed"

    if ! stripe_live_cutover_enabled; then
        fail_with_classification "stripe_live_cutover_disabled" "STRIPE_LIVE_CUTOVER must be set to 1"
    fi
    STRIPE_CUTOVER="true"

    run_sweeper

    if [ "$DRY_RUN" = "true" ]; then
        persist_summary
        return 0
    fi

    local privacy_create_rc=0
    privacy_com_create_card || privacy_create_rc=$?
    persist_privacy_client_capture "privacy_create_card"
    if [ "$privacy_create_rc" -ne 0 ]; then
        fail_with_classification "privacy_card_create_failed" "${PRIVACY_CLIENT_ERROR_MESSAGE:-privacy_com_create_card failed}"
    fi
    if [ "${PRIVACY_CLIENT_EXIT_CLASS:-}" != "ok" ]; then
        fail_with_classification "privacy_card_create_failed" "privacy_com_create_card classification=${PRIVACY_CLIENT_EXIT_CLASS:-unknown}"
    fi

    local card_fields
    card_fields="$(parse_privacy_card_fields)"
    local card_number card_cvc card_exp
    IFS='|' read -r card_number card_cvc card_exp <<< "$card_fields"

    local client_secret
    client_secret="$(create_setup_intent)"

    attach_card_via_setup_intent "$client_secret" "$card_number" "$card_cvc" "$card_exp"
    run_billing_trigger
    run_invoice_webhook_convergence

    cleanup_resources
    persist_summary
}

exit_trap() {
    local original_exit="$?"
    cleanup_resources
    if [ "$SUMMARY_EMITTED" != "true" ] && [ -n "$SUMMARY_PATH" ]; then
        persist_summary >/dev/null
    fi
    exit "$original_exit"
}

if [ -n "${LIVE_E2E_TEST_SHIM:-}" ]; then
    if [ "${LIVE_E2E_ALLOW_TEST_SHIM:-0}" != "1" ]; then
        echo "ERROR: LIVE_E2E_TEST_SHIM requires LIVE_E2E_ALLOW_TEST_SHIM=1" >&2
        exit 64
    fi
    # Test-only seam: sourced after all owner function definitions so unit
    # smoke shims may override any internal helper without ordering surprises.
    # shellcheck source=/dev/null
    source "$LIVE_E2E_TEST_SHIM"
fi

main "$@"
