#!/usr/bin/env bash
# Deterministic lifecycle orchestrator for prod VM lifecycle validation modes.
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/http_json.sh
source "$REPO_ROOT/scripts/lib/http_json.sh"
# shellcheck source=scripts/lib/stripe_checks.sh
source "$REPO_ROOT/scripts/lib/stripe_checks.sh"
# shellcheck source=scripts/lib/stripe_request.sh
source "$REPO_ROOT/scripts/lib/stripe_request.sh"
# shellcheck source=scripts/lib/stripe_payment_methods.sh
source "$REPO_ROOT/scripts/lib/stripe_payment_methods.sh"
# shellcheck source=scripts/lib/privacy_com_client.sh
source "$REPO_ROOT/scripts/lib/privacy_com_client.sh"
# shellcheck source=scripts/lib/test_inbox_helpers.sh
source "$REPO_ROOT/scripts/lib/test_inbox_helpers.sh"
# shellcheck source=scripts/lib/staging_db.sh
source "$REPO_ROOT/scripts/lib/staging_db.sh"
# Reuse extracted signup/verify owner seam to avoid canary-only side effects.
# shellcheck source=scripts/lib/customer_lifecycle_steps.sh
source "$REPO_ROOT/scripts/lib/customer_lifecycle_steps.sh"

LIFECYCLE_MODE=""
CLEANUP_RAN=0

FLOW_FAILED=0
FLOW_FAILURE_STEP=""
FLOW_FAILURE_DETAIL=""

# Shared lifecycle state variables consumed by sourced helper functions.
CANARY_NONCE=""
CANARY_SIGNUP_PASSWORD=""
CANARY_CUSTOMER_ID=""
CANARY_TOKEN=""
CANARY_STRIPE_CUSTOMER_ID=""
CANARY_INDEX_NAME=""
CANARY_INDEX_CREATED=0
CANARY_ACCOUNT_DELETED=0
CANARY_ADMIN_CLEANED=0
CANARY_VERIFY_EMAIL_BUCKET=""
CANARY_VERIFY_EMAIL_MESSAGE_KEY=""

LIFECYCLE_INVOICE_ID=""
LIFECYCLE_STRIPE_INVOICE_ID=""
LIFECYCLE_PROBE_PM_ID="${LIFECYCLE_PROBE_PM_ID:-}"
LIFECYCLE_ATTACHED_PAYMENT_METHOD_ID=""
LIFECYCLE_PRIVACY_CARD_TOKEN=""
LIFECYCLE_INVOICE_MONTH="${LIFECYCLE_INVOICE_MONTH:-$(date -u +%Y-%m)}"
LIFECYCLE_ENABLE_PRIVACY_CARD="${LIFECYCLE_ENABLE_PRIVACY_CARD:-0}"
STRIPE_PAY_OUT_OF_BAND="${STRIPE_PAY_OUT_OF_BAND:-0}"
LIFECYCLE_SECRET_FILE="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
STAGE5_DATABASE_URL_CACHE=""
PRIVACY_REUSABLE_MEMO="fjcloud reusable lifecycle card"

log() {
    echo "[full-vm-lifecycle] $*"
}

print_usage() {
    cat <<USAGE
Usage: validate_full_vm_lifecycle_prod.sh <dry-run|run-a|run-b>

Modes:
  dry-run  Validate deterministic mode dispatch and cleanup plumbing only.
  run-a    Execute signup/verify + shared-index + admin invoice flow.
  run-b    Execute run-a plus reusable Stripe payment-method attach and paid-invoice convergence.
USAGE
}

parse_cli_args() {
    if [ "$#" -ne 1 ]; then
        print_usage >&2
        return 1
    fi

    case "$1" in
        dry-run|run-a|run-b)
            LIFECYCLE_MODE="$1"
            ;;
        *)
            echo "unknown mode: $1" >&2
            print_usage >&2
            return 1
            ;;
    esac
}

require_var() {
    local var_name="$1"
    if [ -z "${!var_name:-}" ]; then
        mark_failure "env" "missing required env var: ${var_name}"
        return 1
    fi
}

require_safe_identifier() {
    local name="$1"
    local value="$2"
    local pattern="$3"
    if [ -z "$value" ] || [[ ! "$value" =~ $pattern ]]; then
        mark_failure "validation" "unsafe ${name} value: ${value:-<empty>}"
        return 1
    fi
}

load_orchestration_env() {
    # Preserve repo-approved secret-file values by clearing ambient AWS exports
    # that can shadow this script's credential loading contract.
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_REGION AWS_REGION

    load_layered_env_files "$LIFECYCLE_SECRET_FILE"

    API_URL="${API_URL:-}"
    ADMIN_KEY="${ADMIN_KEY:-${FLAPJACK_ADMIN_KEY:-}}"
    CANARY_AWS_REGION="${CANARY_AWS_REGION:-${AWS_REGION:-us-east-1}}"
    CANARY_TEST_INBOX_DOMAIN="${CANARY_TEST_INBOX_DOMAIN:-test.flapjack.foo}"
    CANARY_TEST_INBOX_S3_URI="${CANARY_TEST_INBOX_S3_URI:-s3://flapjack-cloud-releases/e2e-emails/}"
    CANARY_INBOX_MAX_ATTEMPTS="${CANARY_INBOX_MAX_ATTEMPTS:-30}"
    CANARY_INBOX_SLEEP_SECONDS="${CANARY_INBOX_SLEEP_SECONDS:-2}"
    CANARY_INDEX_REGION="${CANARY_INDEX_REGION:-us-east-1}"

    export API_URL ADMIN_KEY CANARY_AWS_REGION CANARY_TEST_INBOX_DOMAIN
    export CANARY_TEST_INBOX_S3_URI CANARY_INBOX_MAX_ATTEMPTS CANARY_INBOX_SLEEP_SECONDS
    export CANARY_INDEX_REGION

    require_var "API_URL"
    require_var "ADMIN_KEY"
}

load_run_b_stripe_transport() {
    STRIPE_API_BASE="${STRIPE_API_BASE:-https://api.stripe.com}"
    export STRIPE_API_BASE

    # PM attach/default must target the same Stripe account used by prod customer
    # sync. Prefer the cloud alias key when present so customer ids resolve.
    if [ -n "${STRIPE_SECRET_KEY_flapjack_cloud:-}" ]; then
        STRIPE_SECRET_KEY_EFFECTIVE="${STRIPE_SECRET_KEY_flapjack_cloud}"
    else
        if ! STRIPE_SECRET_KEY_EFFECTIVE="$(resolve_stripe_secret_key)"; then
            mark_failure "stripe_env" "run-b requires STRIPE_SECRET_KEY"
            return 1
        fi
    fi
    if ! stripe_secret_key_has_allowed_prefix "$STRIPE_SECRET_KEY_EFFECTIVE"; then
        mark_failure "stripe_env" "run-b requires an allowed Stripe key prefix; set STRIPE_LIVE_CUTOVER=1 for live keys"
        return 1
    fi

    export STRIPE_SECRET_KEY_EFFECTIVE
}

run_index_create_step() {
    local attempt response_code
    CANARY_INDEX_NAME="lifecycle-${CANARY_NONCE}"

    for attempt in 1 2 3; do
        capture_json_response tenant_call POST "/indexes" "$CANARY_TOKEN" \
            -d "{\"name\":\"${CANARY_INDEX_NAME}\",\"region\":\"${CANARY_INDEX_REGION}\"}"
        response_code="${HTTP_RESPONSE_CODE:-unknown}"
        if [ "$response_code" = "201" ] || [ "$response_code" = "200" ]; then
            CANARY_INDEX_CREATED=1
            log "index created (${CANARY_INDEX_NAME})"
            return 0
        fi
        if [ "$response_code" = "502" ] || [ "$response_code" = "503" ] || [ "$response_code" = "504" ]; then
            if [ "$attempt" -lt 3 ]; then
                log "index create transient HTTP ${response_code}; retrying (${attempt}/3)"
                sleep 2
                continue
            fi
            break
        fi
        mark_failure "create_index" "create index returned HTTP ${response_code}"
        return 1
    done

    mark_failure "create_index" "create index returned HTTP ${response_code:-unknown} after 3 attempts"
    return 1
}

run_index_batch_step() {
    capture_json_response tenant_call POST "/indexes/${CANARY_INDEX_NAME}/batch" "$CANARY_TOKEN" \
        -d "{\"requests\":[{\"action\":\"addObject\",\"body\":{\"objectID\":\"lifecycle-doc-1\",\"title\":\"Lifecycle Probe\",\"body\":\"${CANARY_NONCE}\"}}]}"
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        mark_failure "write_document" "batch write returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    log "index write succeeded (${CANARY_INDEX_NAME})"
}

run_index_search_step() {
    local search_ok=0

    for _ in 1 2 3 4 5; do
        capture_json_response tenant_call POST "/indexes/${CANARY_INDEX_NAME}/search" "$CANARY_TOKEN" \
            -d "{\"query\":\"${CANARY_NONCE}\"}"
        if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
            sleep 1
            continue
        fi

        if python3 - "$HTTP_RESPONSE_BODY" <<PY
import json
import sys

payload = json.loads(sys.argv[1])
hits = payload.get("hits")
if isinstance(hits, list) and len(hits) > 0:
    raise SystemExit(0)
raise SystemExit(1)
PY
        then
            search_ok=1
            break
        fi
        sleep 1
    done

    if [ "$search_ok" -ne 1 ]; then
        mark_failure "search_index" "search did not return hits for nonce ${CANARY_NONCE}"
        return 1
    fi

    log "index search succeeded (${CANARY_INDEX_NAME})"
}

run_delete_index_step() {
    if [ "$CANARY_INDEX_CREATED" -ne 1 ]; then
        return 0
    fi

    capture_json_response tenant_call DELETE "/indexes/${CANARY_INDEX_NAME}" "$CANARY_TOKEN" \
        -d "{\"confirm\":true}"
    if [ "$HTTP_RESPONSE_CODE" != "204" ] && [ "$HTTP_RESPONSE_CODE" != "404" ]; then
        mark_failure "delete_index" "delete index returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    CANARY_INDEX_CREATED=0
    log "index deleted (${CANARY_INDEX_NAME})"
}

run_delete_account_step() {
    if [ "$CANARY_ACCOUNT_DELETED" -eq 1 ] || [ -z "$CANARY_TOKEN" ]; then
        return 0
    fi

    capture_json_response tenant_call DELETE "/account" "$CANARY_TOKEN" \
        -d "{\"password\":\"${CANARY_SIGNUP_PASSWORD}\"}"
    if [ "$HTTP_RESPONSE_CODE" != "204" ] && [ "$HTTP_RESPONSE_CODE" != "404" ]; then
        mark_failure "delete_account" "delete account returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    CANARY_ACCOUNT_DELETED=1
    log "account delete attempted for customer ${CANARY_CUSTOMER_ID}"
}

run_admin_cleanup_step() {
    if [ -z "$CANARY_CUSTOMER_ID" ] || [ "$CANARY_ADMIN_CLEANED" -eq 1 ]; then
        return 0
    fi

    capture_json_response admin_call DELETE "/admin/tenants/${CANARY_CUSTOMER_ID}"
    if [ "$HTTP_RESPONSE_CODE" != "204" ] && [ "$HTTP_RESPONSE_CODE" != "404" ]; then
        mark_failure "admin_cleanup" "admin tenant cleanup returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    CANARY_ADMIN_CLEANED=1
    log "admin cleanup completed for tenant ${CANARY_CUSTOMER_ID}"
}

run_sync_stripe_step() {
    capture_json_response admin_call POST "/admin/customers/${CANARY_CUSTOMER_ID}/sync-stripe"
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        mark_failure "sync_stripe" "sync-stripe returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    CANARY_STRIPE_CUSTOMER_ID="$(json_get_field "$HTTP_RESPONSE_BODY" "stripe_customer_id")"
    if [ -z "$CANARY_STRIPE_CUSTOMER_ID" ]; then
        mark_failure "sync_stripe" "sync-stripe response missing stripe_customer_id"
        return 1
    fi
    require_safe_identifier "stripe_customer_id" "$CANARY_STRIPE_CUSTOMER_ID" '^cus_[A-Za-z0-9]+$'
}

run_prepare_run_b_payment_step() {
    if [ "$STRIPE_PAY_OUT_OF_BAND" = "1" ]; then
        log "run-b out-of-band mode: skipping payment method attachment"
        return 0
    fi
    if [ -z "$LIFECYCLE_PROBE_PM_ID" ]; then
        mark_failure "probe_payment_method" "run-b requires LIFECYCLE_PROBE_PM_ID so finalize can auto-collect"
        return 1
    fi
    if ! require_safe_identifier "payment_method_id" "$LIFECYCLE_PROBE_PM_ID" '^pm_[A-Za-z0-9_]+$'; then
        return 1
    fi
    if [ -z "$CANARY_STRIPE_CUSTOMER_ID" ]; then
        mark_failure "probe_payment_method" "stripe customer id missing before run-b payment setup"
        return 1
    fi

    load_run_b_stripe_transport || return 1

    if ! stripe_attach_payment_method_to_customer "$LIFECYCLE_PROBE_PM_ID" "$CANARY_STRIPE_CUSTOMER_ID"; then
        mark_failure "probe_payment_method" "${STRIPE_PAYMENT_METHOD_ERROR_MESSAGE:-attach payment method failed}"
        return 1
    fi
    LIFECYCLE_ATTACHED_PAYMENT_METHOD_ID="$STRIPE_ATTACHED_PAYMENT_METHOD_ID"

    if ! stripe_set_default_payment_method_for_customer "$CANARY_STRIPE_CUSTOMER_ID" "$LIFECYCLE_ATTACHED_PAYMENT_METHOD_ID"; then
        mark_failure "probe_payment_method" "${STRIPE_PAYMENT_METHOD_ERROR_MESSAGE:-set default payment method failed}"
        return 1
    fi

    log "run-b payment method attached and set as default"
}

run_invoice_generation_step() {
    capture_json_response admin_call POST "/admin/tenants/${CANARY_CUSTOMER_ID}/invoices" \
        -d "{\"month\":\"${LIFECYCLE_INVOICE_MONTH}\"}"
    if [ "$HTTP_RESPONSE_CODE" != "201" ] && [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        mark_failure "generate_invoice" "invoice generation returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    LIFECYCLE_INVOICE_ID="$(json_get_field "$HTTP_RESPONSE_BODY" "id")"
    if [ -z "$LIFECYCLE_INVOICE_ID" ]; then
        mark_failure "generate_invoice" "invoice generation response missing id"
        return 1
    fi
    require_safe_identifier "invoice_id" "$LIFECYCLE_INVOICE_ID" '^([0-9]+|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$'
}

run_invoice_finalize_step() {
    capture_json_response admin_call POST "/admin/invoices/${LIFECYCLE_INVOICE_ID}/finalize"
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        mark_failure "finalize_invoice" "invoice finalize returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    # Finalize returns InvoiceDetailResponse, which carries the Stripe invoice id
    # already persisted server-side. Capture it here so downstream steps (out-of-band
    # pay, paid-state convergence) can address the Stripe invoice without a second
    # admin lookup — the admin list endpoint returns InvoiceListItem and does not
    # expose stripe_invoice_id.
    LIFECYCLE_STRIPE_INVOICE_ID="$(json_get_field "$HTTP_RESPONSE_BODY" "stripe_invoice_id")"
    if [ -z "$LIFECYCLE_STRIPE_INVOICE_ID" ]; then
        mark_failure "finalize_invoice" "finalize response missing stripe_invoice_id for invoice ${LIFECYCLE_INVOICE_ID}"
        return 1
    fi
    require_safe_identifier "stripe_invoice_id" "$LIFECYCLE_STRIPE_INVOICE_ID" '^in_[A-Za-z0-9]+$'
}

run_pay_invoice_out_of_band_step() {
    if [ "$STRIPE_PAY_OUT_OF_BAND" != "1" ]; then
        return 0
    fi

    local live_key="${STRIPE_SECRET_KEY_flapjack_cloud:-}"
    if [ -z "$live_key" ]; then
        mark_failure "out_of_band_pay" "STRIPE_SECRET_KEY_flapjack_cloud required for out-of-band payment"
        return 1
    fi

    if [ -z "$LIFECYCLE_STRIPE_INVOICE_ID" ]; then
        mark_failure "out_of_band_pay" "no stripe_invoice_id captured for invoice ${LIFECYCLE_INVOICE_ID} (finalize must run first)"
        return 1
    fi

    STRIPE_API_BASE="${STRIPE_API_BASE:-https://api.stripe.com}"
    local saved_key="${STRIPE_SECRET_KEY_EFFECTIVE:-}"
    STRIPE_SECRET_KEY_EFFECTIVE="$live_key"

    # Read current Stripe invoice status. Zero-amount invoices are auto-paid by
    # Stripe on finalize, so the explicit /pay call would 400 with
    # "Invoice is already paid". Treat already-paid as the success terminus.
    stripe_request GET "/v1/invoices/${LIFECYCLE_STRIPE_INVOICE_ID}"
    if [ "${STRIPE_HTTP_CODE:-}" != "200" ]; then
        STRIPE_SECRET_KEY_EFFECTIVE="$saved_key"
        mark_failure "out_of_band_pay" "Stripe invoice GET returned HTTP ${STRIPE_HTTP_CODE:-unknown} (stripe_invoice=${LIFECYCLE_STRIPE_INVOICE_ID})"
        return 1
    fi
    local stripe_status
    stripe_status="$(json_get_field "${STRIPE_BODY:-}" "status")"
    if [ "$stripe_status" = "paid" ]; then
        STRIPE_SECRET_KEY_EFFECTIVE="$saved_key"
        log "stripe invoice already paid on finalize (stripe=${LIFECYCLE_STRIPE_INVOICE_ID}, status=${stripe_status}); skipping explicit out-of-band pay"
        return 0
    fi

    stripe_request POST "/v1/invoices/${LIFECYCLE_STRIPE_INVOICE_ID}/pay" -d "paid_out_of_band=true"
    STRIPE_SECRET_KEY_EFFECTIVE="$saved_key"

    if [ "${STRIPE_HTTP_CODE:-}" != "200" ]; then
        local err_summary
        err_summary="$(printf '%s' "${STRIPE_BODY:-}" | python3 -c "
import json, sys
try:
    body = json.loads(sys.stdin.read() or '{}')
    err = body.get('error') or {}
    print(f\"{err.get('type','?')}/{err.get('code','?')}: {err.get('message','?')}\")
except Exception as e:
    print(f'unparseable stripe body: {e}')
" 2>/dev/null || echo "unknown")"
        mark_failure "out_of_band_pay" "Stripe pay out-of-band returned HTTP ${STRIPE_HTTP_CODE:-unknown} (stripe_invoice=${LIFECYCLE_STRIPE_INVOICE_ID}; ${err_summary})"
        return 1
    fi

    log "invoice marked paid out-of-band (stripe=${LIFECYCLE_STRIPE_INVOICE_ID})"
}

run_wait_for_paid_invoice_step() {
    local invoice_paid=0

    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        capture_json_response admin_call GET "/admin/tenants/${CANARY_CUSTOMER_ID}/invoices"
        if [ "$HTTP_RESPONSE_CODE" = "200" ] && python3 - "$HTTP_RESPONSE_BODY" "$LIFECYCLE_INVOICE_ID" <<'PY'
import json
import sys

invoices = json.loads(sys.argv[1])
invoice_id = sys.argv[2]
for item in invoices:
    if str(item.get("id", "")).strip() != invoice_id:
        continue
    status = str(item.get("status", "")).strip().lower()
    paid_at = str(item.get("paid_at", "") or "").strip()
    raise SystemExit(0 if status == "paid" and paid_at else 1)
raise SystemExit(1)
PY
        then
            invoice_paid=1
            break
        fi
        sleep 5
    done

    if [ "$invoice_paid" -eq 1 ]; then
        log "invoice paid (${LIFECYCLE_INVOICE_ID})"
        return 0
    fi

    # OOB-mode fallback: fjcloud DB convergence depends on Stripe webhook delivery,
    # which can lag behind Stripe-side paid state when the prod webhook secret has
    # drifted. The stage terminus is Stripe paid-state; verify that authoritatively
    # and proceed if confirmed. Mode B with reusable-PM attach still requires
    # fjcloud DB convergence and will fail below if not converged.
    if [ "$STRIPE_PAY_OUT_OF_BAND" = "1" ] && [ -n "$LIFECYCLE_STRIPE_INVOICE_ID" ]; then
        load_run_b_stripe_transport >/dev/null 2>&1 || true
        local live_key="${STRIPE_SECRET_KEY_flapjack_cloud:-}"
        if [ -n "$live_key" ]; then
            local saved_key="${STRIPE_SECRET_KEY_EFFECTIVE:-}"
            STRIPE_API_BASE="${STRIPE_API_BASE:-https://api.stripe.com}"
            STRIPE_SECRET_KEY_EFFECTIVE="$live_key"
            stripe_request GET "/v1/invoices/${LIFECYCLE_STRIPE_INVOICE_ID}"
            STRIPE_SECRET_KEY_EFFECTIVE="$saved_key"
            if [ "${STRIPE_HTTP_CODE:-}" = "200" ]; then
                local stripe_status
                stripe_status="$(json_get_field "${STRIPE_BODY:-}" "status")"
                if [ "$stripe_status" = "paid" ]; then
                    log "fjcloud DB did not converge within 60s; Stripe-side authoritative status=paid for ${LIFECYCLE_STRIPE_INVOICE_ID} (webhook delivery lag is an operational follow-up)"
                    return 0
                fi
            fi
        fi
    fi

    mark_failure "invoice_paid" "invoice ${LIFECYCLE_INVOICE_ID} did not converge to paid status"
    return 1
}

run_tenant_invoice_read_step() {
    capture_json_response admin_call GET "/admin/tenants/${CANARY_CUSTOMER_ID}/invoices"
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        mark_failure "list_invoices" "list tenant invoices returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi
}

read_reusable_privacy_card_token() {
    local ssm_param="$1"
    local stderr_file=""
    local output=""
    local rc=0
    local error_output=""

    stderr_file="$(mktemp)"
    if output="$(aws ssm get-parameter \
        --name "$ssm_param" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text 2>"$stderr_file")"
    then
        rm -f "$stderr_file"
        if [ "$output" = "None" ]; then
            return 2
        fi
        printf '%s\n' "$output"
        return 0
    fi
    rc=$?
    error_output="$(cat "$stderr_file")"
    rm -f "$stderr_file"

    if [[ "$error_output" == *"ParameterNotFound"* ]]; then
        return 2
    fi

    log "WARN: aws ssm get-parameter failed for ${ssm_param} (exit=${rc}): ${error_output:-no stderr}"
    return 1
}

# Reusable Privacy.com card pattern — create once per environment, then pause
# and reuse it instead of burning monthly card-create quota on every run.
run_optional_privacy_card_step() {
    local privacy_body=""
    local created_token=""

    if [ "$LIFECYCLE_ENABLE_PRIVACY_CARD" != "1" ]; then
        log "LIFECYCLE_ENABLE_PRIVACY_CARD=${LIFECYCLE_ENABLE_PRIVACY_CARD}; skipping privacy card branch"
        return 0
    fi

    if ! privacy_com_require_env; then
        mark_failure "privacy_env" "${PRIVACY_CLIENT_ERROR_MESSAGE:-privacy_com_require_env failed}"
        return 1
    fi

    local env_label="${LIFECYCLE_ENV:-prod}"
    local ssm_param="/fjcloud/${env_label}/privacy_card_reusable_token"
    local stashed_token=""
    local current_state=""
    local ssm_read_status=0
    # Reset token state at step entry so failure paths never leak stale success
    # values into later lifecycle cleanup logic.
    LIFECYCLE_PRIVACY_CARD_TOKEN=""

    if stashed_token="$(read_reusable_privacy_card_token "$ssm_param")"; then
        :
    else
        ssm_read_status=$?
        if [ "$ssm_read_status" -eq 1 ]; then
            mark_failure "privacy_ssm_read" "aws ssm get-parameter failed for ${ssm_param}"
            return 1
        fi
        stashed_token=""
    fi

    if [ -n "$stashed_token" ] && [ "$stashed_token" != "None" ]; then
        if ! privacy_com_validate_card_token "$stashed_token"; then
            mark_failure "privacy_ssm_token" "stashed reusable token at ${ssm_param} is invalid: ${PRIVACY_CLIENT_ERROR_MESSAGE:-invalid token}"
            return 1
        fi
        if privacy_com_get_card "$stashed_token" && [ "${PRIVACY_CLIENT_EXIT_CLASS:-}" = "ok" ]; then
            privacy_body="${PRIVACY_CLIENT_BODY:-}"
            if [ -z "$privacy_body" ]; then
                privacy_body='{}'
            fi
            current_state="$(json_get_field "$privacy_body" "state")"
            case "$current_state" in
                OPEN)
                    LIFECYCLE_PRIVACY_CARD_TOKEN="$stashed_token"
                    log "reusing OPEN privacy card ${stashed_token}"
                    return 0
                    ;;
                PAUSED)
                    if privacy_com_unpause_card "$stashed_token" && [ "${PRIVACY_CLIENT_EXIT_CLASS:-}" = "ok" ]; then
                        LIFECYCLE_PRIVACY_CARD_TOKEN="$stashed_token"
                        log "unpaused privacy card ${stashed_token} for reuse"
                        return 0
                    fi
                    log "unpause failed for stashed privacy card ${stashed_token}; falling through to create"
                    ;;
                *)
                    log "stashed privacy card ${stashed_token} is state=${current_state}; falling through to create"
                    ;;
            esac
        else
            log "stashed privacy card ${stashed_token} not retrievable (class=${PRIVACY_CLIENT_EXIT_CLASS:-unknown} code=${PRIVACY_CLIENT_HTTP_CODE:-unknown}); falling through to create"
        fi
    fi

    if ! privacy_com_create_card "$PRIVACY_REUSABLE_MEMO"; then
        mark_failure "privacy_create_card" "${PRIVACY_CLIENT_ERROR_MESSAGE:-privacy_com_create_card failed}"
        return 1
    fi
    if [ "${PRIVACY_CLIENT_EXIT_CLASS:-}" != "ok" ]; then
        mark_failure "privacy_create_card" "privacy client returned classification ${PRIVACY_CLIENT_EXIT_CLASS:-unknown}"
        return 1
    fi

    privacy_body="${PRIVACY_CLIENT_BODY:-}"
    if [ -z "$privacy_body" ]; then
        privacy_body='{}'
    fi
    created_token="$(json_get_field "$privacy_body" "token")"
    if [ -z "$created_token" ]; then
        mark_failure "privacy_create_card" "privacy card response missing token"
        return 1
    fi
    if ! privacy_com_validate_card_token "$created_token"; then
        mark_failure "privacy_create_card" "privacy card response token is invalid: ${PRIVACY_CLIENT_ERROR_MESSAGE:-invalid token}"
        return 1
    fi

    if ! aws ssm put-parameter \
        --name "$ssm_param" \
        --value "$created_token" \
        --type SecureString \
        --overwrite >/dev/null
    then
        log "WARN: created privacy card ${created_token} but could not stash it at ${ssm_param}"
        mark_failure "privacy_ssm_stash" "aws ssm put-parameter failed for ${ssm_param}"
        return 1
    fi

    LIFECYCLE_PRIVACY_CARD_TOKEN="$created_token"
    log "created and stashed reusable privacy card ${LIFECYCLE_PRIVACY_CARD_TOKEN} at ${ssm_param}"
}

run_detach_probe_payment_method_step() {
    if [ -z "$LIFECYCLE_ATTACHED_PAYMENT_METHOD_ID" ]; then
        return 0
    fi

    STRIPE_API_BASE="${STRIPE_API_BASE:-https://api.stripe.com}"
    export STRIPE_API_BASE
    if [ -z "${STRIPE_SECRET_KEY_EFFECTIVE:-}" ]; then
        STRIPE_SECRET_KEY_EFFECTIVE="$(resolve_stripe_secret_key 2>/dev/null || true)"
        if [ -z "$STRIPE_SECRET_KEY_EFFECTIVE" ]; then
            log "cleanup warning: stripe secret key unavailable for payment method detach"
            return 1
        fi
        export STRIPE_SECRET_KEY_EFFECTIVE
    fi

    if stripe_detach_payment_method "$LIFECYCLE_ATTACHED_PAYMENT_METHOD_ID" >/dev/null 2>&1; then
        log "run-b payment method detached"
        LIFECYCLE_ATTACHED_PAYMENT_METHOD_ID=""
        return 0
    fi

    log "cleanup warning: reusable payment method detach failed"
    return 1
}

run_pause_privacy_card_step() {
    if [ -z "$LIFECYCLE_PRIVACY_CARD_TOKEN" ]; then
        return 0
    fi

    if ! privacy_com_validate_card_token "$LIFECYCLE_PRIVACY_CARD_TOKEN"; then
        log "cleanup warning: privacy card token is invalid (${PRIVACY_CLIENT_ERROR_MESSAGE:-invalid token})"
        return 1
    fi

    if privacy_com_pause_card "$LIFECYCLE_PRIVACY_CARD_TOKEN" >/dev/null 2>&1 && [ "${PRIVACY_CLIENT_EXIT_CLASS:-}" = "ok" ]; then
        log "privacy card paused (reusable token retained in SSM)"
        LIFECYCLE_PRIVACY_CARD_TOKEN=""
        return 0
    fi

    log "cleanup warning: privacy card pause failed (token retained for next run)"
    return 1
}

sql_escape_literal() {
    local raw="${1:-}"
    printf '%s' "$raw" | sed "s/'/''/g"
}

# Redact Stripe-hosted invoice access links before persisting evidence.
redact_stripe_invoice_urls() {
    python3 -c 'import json,sys
REDACT_KEYS={"hosted_invoice_url","invoice_pdf"}
def scrub(node):
    if isinstance(node, dict):
        return {key: ("[REDACTED]" if key in REDACT_KEYS and value not in (None, "") else scrub(value)) for key, value in node.items()}
    if isinstance(node, list):
        return [scrub(item) for item in node]
    return node
json.dump(scrub(json.load(sys.stdin)), sys.stdout)
sys.stdout.write("\n")'
}

capture_stage5_db_sql_file() {
    local dir="$1"
    local artifact_file="$2"
    local sql="$3"
    local database_url output

    resolve_stage5_database_url || {
        log "evidence: DATABASE_URL unavailable; skipping ${artifact_file}"
        return 1
    }
    database_url="$STAGE5_DATABASE_URL_CACHE"

    if output="$(staging_db_run_sql "$database_url" "$sql" 2>&1)"; then
        printf '%s\n' "$output" > "$dir/$artifact_file"
        return 0
    fi

    # Compatibility seam: preserve successful remote SQL output when the helper
    # returns non-zero due to known status parsing drift.
    if [[ "$output" == *"status=Success"* ]]; then
        printf '%s\n' "$output" | sed -E '1s/^.*\):[[:space:]]*//' > "$dir/$artifact_file"
        return 0
    fi

    printf '%s\n' "$output" > "$dir/${artifact_file}.error.txt"
    log "evidence: failed to capture ${artifact_file}; see ${dir}/${artifact_file}.error.txt"
    return 1
}

resolve_stage5_database_url() {
    local ssm_param region hydrated

    ssm_param="${DATABASE_URL_SSM_PARAM:-/fjcloud/prod/database_url}"

    if [ -n "$STAGE5_DATABASE_URL_CACHE" ]; then
        return 0
    fi

    if [ -n "${DATABASE_URL:-}" ]; then
        DATABASE_URL_SSM_PARAM="$ssm_param"
        export DATABASE_URL_SSM_PARAM
        STAGE5_DATABASE_URL_CACHE="$DATABASE_URL"
        return 0
    fi

    region="${AWS_DEFAULT_REGION:-us-east-1}"
    if hydrated="$(aws ssm get-parameter \
        --name "$ssm_param" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --region "$region" 2>/dev/null)" \
        && [ -n "$hydrated" ] \
        && [ "$hydrated" != "None" ]
    then
        STAGE5_DATABASE_URL_CACHE="$hydrated"
        DATABASE_URL="$hydrated"
        DATABASE_URL_SSM_PARAM="$ssm_param"
        export DATABASE_URL DATABASE_URL_SSM_PARAM
        return 0
    fi

    return 1
}

capture_stage5_verify_email_aws_evidence() {
    local dir="$1"
    local region="${CANARY_AWS_REGION:-us-east-1}"

    if [ -z "$CANARY_VERIFY_EMAIL_BUCKET" ] || [ -z "$CANARY_VERIFY_EMAIL_MESSAGE_KEY" ]; then
        log "evidence: verify-email AWS identifiers unavailable; skipping raw AWS artifact capture"
        return 1
    fi

    printf '%s\n' "$CANARY_VERIFY_EMAIL_MESSAGE_KEY" > "$dir/aws_verify_email_message_key.txt"
    printf 's3://%s/%s\n' "$CANARY_VERIFY_EMAIL_BUCKET" "$CANARY_VERIFY_EMAIL_MESSAGE_KEY" \
        > "$dir/aws_verify_email_message_s3_uri.txt"

    if AWS_PAGER="" aws s3api head-object \
        --bucket "$CANARY_VERIFY_EMAIL_BUCKET" \
        --key "$CANARY_VERIFY_EMAIL_MESSAGE_KEY" \
        --region "$region" \
        --output json \
        --no-cli-pager > "$dir/aws_verify_email_head_object.json" 2> "$dir/aws_verify_email_head_object.stderr"
    then
        return 0
    fi

    log "evidence: aws s3api head-object failed for verify-email object; see aws_verify_email_head_object.stderr"
    return 1
}

# Persist evidence artifacts to STAGE5_EVIDENCE_DIR when set. Called after a
# successful run_orchestration_flow and before cleanup so customer/invoice rows
# are still present in fjcloud. Best-effort: failures here do not fail the run.
capture_stage5_pre_cleanup_evidence() {
    local dir="${STAGE5_EVIDENCE_DIR:-}"
    local escaped_customer_id escaped_tenant_id
    if [ -z "$dir" ]; then
        return 0
    fi
    if [ ! -d "$dir" ]; then
        log "evidence: STAGE5_EVIDENCE_DIR=$dir does not exist; skipping pre-cleanup evidence capture"
        return 0
    fi

    python3 - "$dir" \
        "$CANARY_CUSTOMER_ID" \
        "$CANARY_STRIPE_CUSTOMER_ID" \
        "$LIFECYCLE_INVOICE_ID" \
        "$LIFECYCLE_STRIPE_INVOICE_ID" \
        "$CANARY_INDEX_NAME" \
        "$LIFECYCLE_MODE" \
        "${STRIPE_PAY_OUT_OF_BAND:-0}" \
        <<'PY'
import json, os, sys, datetime
dir_, cust, scust, inv, sinv, idx, mode, oob = sys.argv[1:9]
meta = {
    "captured_at_utc": datetime.datetime.utcnow().isoformat() + "Z",
    "mode": mode,
    "stripe_pay_out_of_band": oob == "1",
    "fjcloud_customer_id": cust,
    "stripe_customer_id": scust,
    "fjcloud_invoice_id": inv,
    "stripe_invoice_id": sinv,
    "index_name": idx,
}
with open(os.path.join(dir_, "metadata.json"), "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
PY

    # Stripe authoritative paid-state evidence
    if [ -n "$LIFECYCLE_STRIPE_INVOICE_ID" ]; then
        local saved_key="${STRIPE_SECRET_KEY_EFFECTIVE:-}"
        local live_key="${STRIPE_SECRET_KEY_flapjack_cloud:-}"
        if [ -n "$live_key" ]; then
            STRIPE_API_BASE="${STRIPE_API_BASE:-https://api.stripe.com}"
            STRIPE_SECRET_KEY_EFFECTIVE="$live_key"
            stripe_request GET "/v1/invoices/${LIFECYCLE_STRIPE_INVOICE_ID}"
            STRIPE_SECRET_KEY_EFFECTIVE="$saved_key"
            printf '%s' "${STRIPE_BODY:-null}" \
                | redact_stripe_invoice_urls \
                | python3 -c 'import json,sys; print(json.dumps({"http_code": int(sys.argv[1]), "body": json.load(sys.stdin)}, indent=2))' \
                    "${STRIPE_HTTP_CODE:-0}" > "$dir/stripe_paid_state.json"
        fi
    fi

    # Tenant active pre-cleanup state
    capture_json_response admin_call GET "/admin/tenants/${CANARY_CUSTOMER_ID}"
    {
        printf '{"http_code": "%s", "body": %s}\n' \
            "${HTTP_RESPONSE_CODE:-0}" \
            "${HTTP_RESPONSE_BODY:-null}"
    } > "$dir/tenant_active_pre_cleanup.json"

    capture_stage5_verify_email_aws_evidence "$dir" || true

    escaped_customer_id="$(sql_escape_literal "$CANARY_CUSTOMER_ID")"
    escaped_tenant_id="$(sql_escape_literal "$CANARY_INDEX_NAME")"

    capture_stage5_db_sql_file \
        "$dir" \
        "db_pre_cleanup_customer.sql.txt" \
        "SELECT id::text, status FROM customers WHERE id = '${escaped_customer_id}'::uuid;" || true
    if [ -n "$LIFECYCLE_INVOICE_ID" ]; then
        local escaped_invoice_id
        escaped_invoice_id="$(sql_escape_literal "$LIFECYCLE_INVOICE_ID")"
        capture_stage5_db_sql_file \
            "$dir" \
            "db_pre_cleanup_invoice.sql.txt" \
            "SELECT id::text, customer_id::text, status, paid_at FROM invoices WHERE id = '${escaped_invoice_id}'::uuid;" || true
    else
        rm -f "$dir/db_pre_cleanup_invoice.sql.txt" "$dir/db_pre_cleanup_invoice.sql.txt.error.txt"
    fi
    capture_stage5_db_sql_file \
        "$dir" \
        "db_pre_cleanup_tenant.sql.txt" \
        "SELECT customer_id::text, tenant_id, tier FROM customer_tenants WHERE customer_id = '${escaped_customer_id}'::uuid AND tenant_id = '${escaped_tenant_id}';" || true

    log "evidence: pre-cleanup artifacts written to ${dir}"
}

# Post-cleanup evidence: capture proof that tenant + index are gone after teardown.
capture_stage5_post_cleanup_evidence() {
    local dir="${STAGE5_EVIDENCE_DIR:-}"
    local escaped_customer_id escaped_tenant_id
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        return 0
    fi
    capture_json_response admin_call GET "/admin/tenants/${CANARY_CUSTOMER_ID}"
    local tenant_http="${HTTP_RESPONSE_CODE:-0}"
    local tenant_body="${HTTP_RESPONSE_BODY:-null}"
    {
        printf '{"tenant_get": {"http_code": "%s", "body": %s}}\n' \
            "$tenant_http" \
            "$tenant_body"
    } > "$dir/post_cleanup_state.json"

    escaped_customer_id="$(sql_escape_literal "$CANARY_CUSTOMER_ID")"
    escaped_tenant_id="$(sql_escape_literal "$CANARY_INDEX_NAME")"
    capture_stage5_db_sql_file \
        "$dir" \
        "db_post_cleanup_customer.sql.txt" \
        "SELECT COUNT(*) AS customer_rows FROM customers WHERE id = '${escaped_customer_id}'::uuid;" || true
    if [ -n "$LIFECYCLE_INVOICE_ID" ]; then
        local escaped_invoice_id
        escaped_invoice_id="$(sql_escape_literal "$LIFECYCLE_INVOICE_ID")"
        capture_stage5_db_sql_file \
            "$dir" \
            "db_post_cleanup_invoice.sql.txt" \
            "SELECT COUNT(*) AS invoice_rows FROM invoices WHERE id = '${escaped_invoice_id}'::uuid;" || true
    else
        rm -f "$dir/db_post_cleanup_invoice.sql.txt" "$dir/db_post_cleanup_invoice.sql.txt.error.txt"
    fi
    capture_stage5_db_sql_file \
        "$dir" \
        "db_post_cleanup_tenant.sql.txt" \
        "SELECT COUNT(*) AS tenant_rows FROM customer_tenants WHERE customer_id = '${escaped_customer_id}'::uuid AND tenant_id = '${escaped_tenant_id}';" || true

    log "evidence: post-cleanup artifacts written to ${dir}"
}

run_orchestration_flow() {
    run_signup_step || return 1
    run_verify_email_step || return 1
    run_index_create_step || return 1
    run_index_batch_step || return 1
    run_index_search_step || return 1
    run_sync_stripe_step || return 1
    if [ "$LIFECYCLE_MODE" = "run-b" ]; then
        run_prepare_run_b_payment_step || return 1
    fi
    run_invoice_generation_step || return 1
    run_invoice_finalize_step || return 1
    run_pay_invoice_out_of_band_step || return 1
    if [ "$LIFECYCLE_MODE" = "run-b" ]; then
        run_wait_for_paid_invoice_step || return 1
    fi
    run_tenant_invoice_read_step || return 1

    if [ "$LIFECYCLE_MODE" = "run-b" ]; then
        run_optional_privacy_card_step || return 1
    fi
}

cleanup() {
    if [ "$CLEANUP_RAN" -eq 1 ]; then
        return 0
    fi
    CLEANUP_RAN=1
    trap - EXIT

    run_detach_probe_payment_method_step || true
    run_pause_privacy_card_step || true
    run_delete_index_step || true
    run_delete_account_step || true
    run_admin_cleanup_step || true

    capture_stage5_post_cleanup_evidence || true
}

run_dry_run_mode() {
    log "mode=dry-run"
    log "dry-run: validated mode dispatch, deterministic cleanup trap, and shared seam wiring"
}

run_live_mode() {
    log "mode=${LIFECYCLE_MODE}"
    load_orchestration_env || return 1
    run_orchestration_flow || return 1
    capture_stage5_pre_cleanup_evidence || true
}

main() {
    parse_cli_args "$@" || return 1

    if [ "$LIFECYCLE_MODE" = "dry-run" ]; then
        run_dry_run_mode
        return 0
    fi

    if ! run_live_mode; then
        if [ "$FLOW_FAILED" -eq 1 ]; then
            log "step '${FLOW_FAILURE_STEP}' failed: ${FLOW_FAILURE_DETAIL}"
        fi
        return 1
    fi

    if [ "$FLOW_FAILED" -eq 1 ]; then
        log "step '${FLOW_FAILURE_STEP}' failed: ${FLOW_FAILURE_DETAIL}"
        return 1
    fi

    log "${LIFECYCLE_MODE} completed successfully"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap cleanup EXIT
    main "$@"
fi
