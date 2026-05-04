#!/usr/bin/env bash
# customer_loop_synthetic.sh — staging customer-loop canary owner.
#
# Stage 4 scope in this owner:
# - enforce quiet-window short-circuit before any HTTP work
# - run signup -> verification -> Stripe setup-intent wiring -> index loop
# - enforce deterministic teardown (index, account, admin cleanup)
# - dispatch failures only via send_critical_alert

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

# shellcheck source=scripts/lib/http_json.sh
source "$REPO_ROOT/scripts/lib/http_json.sh"

ALERT_DISPATCH_IMPL="${ALERT_DISPATCH_HELPER:-$REPO_ROOT/scripts/lib/alert_dispatch.sh}"
# shellcheck source=scripts/lib/alert_dispatch.sh
source "$ALERT_DISPATCH_IMPL"

# shellcheck source=scripts/lib/test_inbox_helpers.sh
source "$REPO_ROOT/scripts/lib/test_inbox_helpers.sh"

# shellcheck source=scripts/lib/stripe_request.sh
source "$REPO_ROOT/scripts/lib/stripe_request.sh"

HTTP_RESPONSE_BODY=""
HTTP_RESPONSE_CODE=""
STRIPE_HTTP_CODE=""
STRIPE_BODY=""

FLOW_FAILED=0
FLOW_FAILURE_STEP=""
FLOW_FAILURE_DETAIL=""

CANARY_NONCE=""
CANARY_SIGNUP_EMAIL=""
CANARY_SIGNUP_PASSWORD=""
CANARY_CUSTOMER_ID=""
CANARY_TOKEN=""
CANARY_INDEX_NAME=""
CANARY_INDEX_CREATED=0
CANARY_ACCOUNT_DELETED=0
CANARY_ADMIN_CLEANED=0
CANARY_STRIPE_CUSTOMER_ID=""
CANARY_LIVE_INVOICE_ID=""
CANARY_LIVE_CHARGE_ID=""
CANARY_LIVE_REFUND_ID=""
CANARY_LIVE_PAYMENT_EVENT_ID=""
CANARY_LIVE_MODE_CLI_OVERRIDE=""
CANARY_SHOW_HELP=0

log() {
    echo "[customer-loop-canary] $*"
}

mark_failure() {
    local step_name="$1"
    local detail_message="$2"

    if [ "$FLOW_FAILED" -eq 0 ]; then
        FLOW_FAILED=1
        FLOW_FAILURE_STEP="$step_name"
        FLOW_FAILURE_DETAIL="$detail_message"
    fi
}

load_canary_env() {
    local default_secret_file="$REPO_ROOT/.secret/.env.secret"
    local secret_file="${FJCLOUD_SECRET_FILE:-$default_secret_file}"

    load_env_file "$secret_file"

    ENVIRONMENT="${ENVIRONMENT:-staging}"
    API_URL="${API_URL:-http://localhost:3001}"
    ADMIN_KEY="${ADMIN_KEY:-${FLAPJACK_ADMIN_KEY:-}}"
    CANARY_ALERT_SOURCE="${CANARY_ALERT_SOURCE:-scripts/canary/customer_loop_synthetic.sh}"
    CANARY_ALERT_NONCE="${CANARY_ALERT_NONCE:-customer-loop-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}}"

    CANARY_AWS_REGION="${CANARY_AWS_REGION:-${AWS_REGION:-us-east-1}}"
    CANARY_TEST_INBOX_DOMAIN="${CANARY_TEST_INBOX_DOMAIN:-test.flapjack.foo}"
    CANARY_TEST_INBOX_S3_URI="${CANARY_TEST_INBOX_S3_URI:-s3://flapjack-cloud-releases/e2e-emails/}"
    CANARY_INBOX_MAX_ATTEMPTS="${CANARY_INBOX_MAX_ATTEMPTS:-30}"
    CANARY_INBOX_SLEEP_SECONDS="${CANARY_INBOX_SLEEP_SECONDS:-2}"

    CANARY_INDEX_REGION="${CANARY_INDEX_REGION:-us-east-1}"
    STRIPE_API_BASE="${STRIPE_API_BASE:-https://api.stripe.com}"
    STRIPE_SECRET_KEY_EFFECTIVE="${STRIPE_SECRET_KEY:-${STRIPE_TEST_SECRET_KEY:-}}"
    CANARY_LIVE_MODE="${CANARY_LIVE_MODE:-0}"

    export ENVIRONMENT API_URL ADMIN_KEY CANARY_ALERT_SOURCE CANARY_ALERT_NONCE
    export CANARY_AWS_REGION CANARY_TEST_INBOX_DOMAIN CANARY_TEST_INBOX_S3_URI
    export CANARY_INBOX_MAX_ATTEMPTS CANARY_INBOX_SLEEP_SECONDS CANARY_INDEX_REGION
    export STRIPE_API_BASE STRIPE_SECRET_KEY_EFFECTIVE CANARY_LIVE_MODE
}

json_get_field() {
    local json_body="$1"
    local field_name="$2"

    python3 - "$json_body" "$field_name" <<'PY' || true
import json
import sys

payload = json.loads(sys.argv[1])
field_name = sys.argv[2]
value = payload.get(field_name, "")
if value is None:
    print("")
elif isinstance(value, (int, float, bool)):
    print(str(value).lower() if isinstance(value, bool) else str(value))
else:
    print(str(value))
PY
}

parse_epoch_seconds() {
    local raw_value="$1"

    if [[ "$raw_value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$raw_value"
        return 0
    fi

    python3 - "$raw_value" <<'PY'
import datetime
import sys

raw = sys.argv[1].strip()
if not raw:
    raise SystemExit(1)
if raw.endswith("Z"):
    raw = raw[:-1] + "+00:00"
try:
    dt = datetime.datetime.fromisoformat(raw)
except ValueError:
    raise SystemExit(1)
print(int(dt.timestamp()))
PY
}

resolve_quiet_until_raw() {
    if [ -n "${CANARY_QUIET_UNTIL_OVERRIDE:-}" ]; then
        printf '%s\n' "$CANARY_QUIET_UNTIL_OVERRIDE"
        return 0
    fi

    aws ssm get-parameter \
        --name "/fjcloud/${ENVIRONMENT}/canary_quiet_until" \
        --query 'Parameter.Value' \
        --output text
}

quiet_window_active() {
    local quiet_until_raw quiet_until_epoch now_epoch

    quiet_until_raw="$(resolve_quiet_until_raw 2>/dev/null || true)"
    if [ -z "$quiet_until_raw" ]; then
        return 1
    fi

    quiet_until_epoch="$(parse_epoch_seconds "$quiet_until_raw" 2>/dev/null || true)"
    if [ -z "$quiet_until_epoch" ]; then
        return 1
    fi

    now_epoch="$(date +%s)"
    [ "$quiet_until_epoch" -gt "$now_epoch" ]
}

dispatch_failure_alert() {
    local failed_step="$1"
    local detail_message="$2"
    local title message

    title="[fjcloud canary ${ENVIRONMENT}] customer loop failed at ${failed_step}"
    message="customer-loop canary failed during '${failed_step}'. ${detail_message}"

    if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
        send_critical_alert \
            "slack" \
            "$SLACK_WEBHOOK_URL" \
            "$title" \
            "$message" \
            "$CANARY_ALERT_SOURCE" \
            "$CANARY_ALERT_NONCE" \
            "$ENVIRONMENT" || true
    fi

    if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
        send_critical_alert \
            "discord" \
            "$DISCORD_WEBHOOK_URL" \
            "$title" \
            "$message" \
            "$CANARY_ALERT_SOURCE" \
            "$CANARY_ALERT_NONCE" \
            "$ENVIRONMENT" || true
    fi
}

print_usage() {
    cat <<'USAGE'
Usage: customer_loop_synthetic.sh [--dry-run|--live] [--help]

Options:
  --dry-run   Run signup/verify/index flow only and skip all Stripe-mutating steps (default).
  --live      Enable Stripe-mutating canary flow (sync, attach, invoice, pay, refund, webhook verify).
  --help      Print this help message.
USAGE
}

parse_cli_args() {
    CANARY_LIVE_MODE_CLI_OVERRIDE=""
    CANARY_SHOW_HELP=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)
                CANARY_LIVE_MODE_CLI_OVERRIDE="0"
                ;;
            --live)
                CANARY_LIVE_MODE_CLI_OVERRIDE="1"
                ;;
            --help|-h)
                CANARY_SHOW_HELP=1
                ;;
            *)
                echo "unknown argument: $1" >&2
                print_usage >&2
                return 1
                ;;
        esac
        shift
    done

    return 0
}

run_signup_step() {
    CANARY_NONCE="canary$(date -u +%Y%m%d%H%M%S)${RANDOM}"
    CANARY_SIGNUP_EMAIL="canary+${CANARY_NONCE}@${CANARY_TEST_INBOX_DOMAIN}"
    CANARY_SIGNUP_PASSWORD="customer-loop-pass-1234"

    capture_json_response api_json_call POST "/auth/register" \
        -d "{\"name\":\"Staging Customer Canary\",\"email\":\"${CANARY_SIGNUP_EMAIL}\",\"password\":\"${CANARY_SIGNUP_PASSWORD}\"}"

    if [ "$HTTP_RESPONSE_CODE" != "201" ] && [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        mark_failure "signup" "register returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    CANARY_TOKEN="$(json_get_field "$HTTP_RESPONSE_BODY" "token")"
    CANARY_CUSTOMER_ID="$(json_get_field "$HTTP_RESPONSE_BODY" "customer_id")"
    if [ -z "$CANARY_TOKEN" ] || [ -z "$CANARY_CUSTOMER_ID" ]; then
        mark_failure "signup" "register response did not include token/customer_id"
        return 1
    fi

    log "signup succeeded for ${CANARY_SIGNUP_EMAIL} (customer=${CANARY_CUSTOMER_ID})"
}

run_verify_email_step() {
    local bucket prefix parsed_s3 message_key rfc822_payload verify_token

    parsed_s3="$(test_inbox_parse_s3_uri "$CANARY_TEST_INBOX_S3_URI" 2>/dev/null || true)"
    if [ -z "$parsed_s3" ]; then
        mark_failure "verify_email" "invalid CANARY_TEST_INBOX_S3_URI (${CANARY_TEST_INBOX_S3_URI})"
        return 1
    fi
    bucket="${parsed_s3%%|*}"
    prefix="${parsed_s3#*|}"

    message_key="$(test_inbox_find_matching_object_key \
        "$bucket" \
        "$prefix" \
        "$CANARY_NONCE" \
        "$CANARY_AWS_REGION" \
        "$CANARY_INBOX_MAX_ATTEMPTS" \
        "$CANARY_INBOX_SLEEP_SECONDS" 2>/dev/null || true)"
    if [ -z "$message_key" ]; then
        mark_failure "verify_email" "verification email not found in inbox within timeout"
        return 1
    fi

    rfc822_payload="$(test_inbox_fetch_rfc822 "$bucket" "$message_key" "$CANARY_AWS_REGION" 2>/dev/null || true)"
    if [ -z "$rfc822_payload" ]; then
        mark_failure "verify_email" "unable to fetch verification message from s3://${bucket}/${message_key}"
        return 1
    fi

    verify_token="$(test_inbox_extract_verify_token_from_rfc822 "$rfc822_payload")"
    if [ -z "$verify_token" ]; then
        mark_failure "verify_email" "verification token missing in RFC822 payload"
        return 1
    fi

    capture_json_response api_json_call POST "/auth/verify-email" \
        -d "{\"token\":\"${verify_token}\"}"
    if [ "$HTTP_RESPONSE_CODE" != "200" ] && [ "$HTTP_RESPONSE_CODE" != "204" ]; then
        mark_failure "verify_email" "verify-email returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    log "email verification succeeded for ${CANARY_SIGNUP_EMAIL}"
}

run_sync_stripe_step() {
    if [ -z "$ADMIN_KEY" ]; then
        mark_failure "sync_stripe" "ADMIN_KEY is required for /admin/customers/{id}/sync-stripe"
        return 1
    fi

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

    log "stripe sync succeeded (stripe_customer_id=${CANARY_STRIPE_CUSTOMER_ID})"
}

run_setup_intent_and_stripe_attach_step() {
    local client_secret attached_payment_method

    capture_json_response tenant_call POST "/billing/setup-intent" "$CANARY_TOKEN"
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        mark_failure "setup_intent" "setup-intent returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    client_secret="$(json_get_field "$HTTP_RESPONSE_BODY" "client_secret")"
    if [ -z "$client_secret" ]; then
        mark_failure "setup_intent" "setup-intent response missing client_secret"
        return 1
    fi

    if [ -z "$STRIPE_SECRET_KEY_EFFECTIVE" ]; then
        mark_failure "stripe_attach" "STRIPE_SECRET_KEY (or STRIPE_TEST_SECRET_KEY) is required"
        return 1
    fi
    if [[ "$STRIPE_API_BASE" != "https://api.stripe.com" && "$STRIPE_API_BASE" != "https://api.stripe.com/" ]]; then
        mark_failure "stripe_attach" "STRIPE_API_BASE must remain https://api.stripe.com"
        return 1
    fi

    if ! stripe_request POST "/v1/payment_methods/pm_card_visa/attach" -d "customer=$CANARY_STRIPE_CUSTOMER_ID"; then
        mark_failure "stripe_attach" "curl failure while attaching pm_card_visa: ${STRIPE_BODY:-unknown}"
        return 1
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ]; then
        mark_failure "stripe_attach" "attach payment method failed with HTTP ${STRIPE_HTTP_CODE}"
        return 1
    fi

    attached_payment_method="$(json_get_field "$STRIPE_BODY" "id")"
    if [ -z "$attached_payment_method" ]; then
        mark_failure "stripe_attach" "attach payment method response missing id"
        return 1
    fi

    if ! stripe_request POST "/v1/customers/$CANARY_STRIPE_CUSTOMER_ID" \
        -d "invoice_settings[default_payment_method]=$attached_payment_method"; then
        mark_failure "stripe_attach" "curl failure while setting default payment method: ${STRIPE_BODY:-unknown}"
        return 1
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ]; then
        mark_failure "stripe_attach" "set default payment method failed with HTTP ${STRIPE_HTTP_CODE}"
        return 1
    fi

    log "setup-intent succeeded and payment method attached as default"
}

run_live_create_invoice_step() {
    local invoice_id charge_id

    if [ -z "$CANARY_STRIPE_CUSTOMER_ID" ]; then
        mark_failure "live_create_invoice" "CANARY_STRIPE_CUSTOMER_ID missing before invoice flow"
        return 1
    fi

    if ! stripe_request POST "/v1/invoices" \
        -d "customer=$CANARY_STRIPE_CUSTOMER_ID" \
        -d "currency=usd"; then
        mark_failure "live_create_invoice" "curl failure while creating invoice: ${STRIPE_BODY:-unknown}"
        return 1
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ]; then
        mark_failure "live_create_invoice" "create invoice failed with HTTP ${STRIPE_HTTP_CODE}"
        return 1
    fi
    invoice_id="$(json_get_field "$STRIPE_BODY" "id")"
    if [ -z "$invoice_id" ]; then
        mark_failure "live_create_invoice" "create invoice response missing id"
        return 1
    fi

    if ! stripe_request POST "/v1/invoiceitems" \
        -d "customer=$CANARY_STRIPE_CUSTOMER_ID" \
        -d "invoice=$invoice_id" \
        -d "amount=50" \
        -d "currency=usd" \
        -d "description=Customer loop live canary charge"; then
        mark_failure "live_create_invoice" "curl failure while creating invoice item: ${STRIPE_BODY:-unknown}"
        return 1
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ]; then
        mark_failure "live_create_invoice" "create invoice item failed with HTTP ${STRIPE_HTTP_CODE}"
        return 1
    fi

    if ! stripe_request POST "/v1/invoices/${invoice_id}/finalize"; then
        mark_failure "live_create_invoice" "curl failure while finalizing invoice: ${STRIPE_BODY:-unknown}"
        return 1
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ]; then
        mark_failure "live_create_invoice" "finalize invoice failed with HTTP ${STRIPE_HTTP_CODE}"
        return 1
    fi

    if ! stripe_request POST "/v1/invoices/${invoice_id}/pay"; then
        mark_failure "live_create_invoice" "curl failure while paying invoice: ${STRIPE_BODY:-unknown}"
        return 1
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ]; then
        mark_failure "live_create_invoice" "pay invoice failed with HTTP ${STRIPE_HTTP_CODE}"
        return 1
    fi

    charge_id="$(json_get_field "$STRIPE_BODY" "charge")"
    if [ -z "$charge_id" ]; then
        mark_failure "live_create_invoice" "pay invoice response missing charge id"
        return 1
    fi

    CANARY_LIVE_INVOICE_ID="$invoice_id"
    CANARY_LIVE_CHARGE_ID="$charge_id"
    log "live invoice paid (invoice=${CANARY_LIVE_INVOICE_ID} charge=${CANARY_LIVE_CHARGE_ID})"
}

run_live_refund_step() {
    if [ -z "$CANARY_LIVE_CHARGE_ID" ]; then
        mark_failure "live_refund" "CANARY_LIVE_CHARGE_ID missing before refund step"
        return 1
    fi

    if ! stripe_request POST "/v1/refunds" \
        -d "charge=$CANARY_LIVE_CHARGE_ID" \
        -d "reason=requested_by_customer"; then
        mark_failure "live_refund" "curl failure while refunding charge: ${STRIPE_BODY:-unknown}"
        return 1
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ]; then
        mark_failure "live_refund" "refund failed with HTTP ${STRIPE_HTTP_CODE}"
        return 1
    fi

    CANARY_LIVE_REFUND_ID="$(json_get_field "$STRIPE_BODY" "id")"
    if [ -z "$CANARY_LIVE_REFUND_ID" ]; then
        mark_failure "live_refund" "refund response missing id"
        return 1
    fi

    log "live refund succeeded (refund=${CANARY_LIVE_REFUND_ID})"
}

run_live_find_payment_event_step() {
    CANARY_LIVE_PAYMENT_EVENT_ID=""

    if [ -z "$CANARY_LIVE_INVOICE_ID" ]; then
        mark_failure "live_find_payment_event" "CANARY_LIVE_INVOICE_ID missing before event lookup"
        return 1
    fi

    if ! stripe_request GET "/v1/events?type=invoice.payment_succeeded&limit=25"; then
        mark_failure "live_find_payment_event" "curl failure while listing events: ${STRIPE_BODY:-unknown}"
        return 1
    fi
    if [ "$STRIPE_HTTP_CODE" != "200" ]; then
        mark_failure "live_find_payment_event" "list events failed with HTTP ${STRIPE_HTTP_CODE}"
        return 1
    fi

    CANARY_LIVE_PAYMENT_EVENT_ID="$(python3 - "$STRIPE_BODY" "$CANARY_LIVE_INVOICE_ID" <<'PY' || true
import json
import sys

payload = json.loads(sys.argv[1])
invoice_id = sys.argv[2]
for event in payload.get("data", []):
    if not isinstance(event, dict):
        continue
    if event.get("type") != "invoice.payment_succeeded":
        continue
    data = event.get("data")
    if not isinstance(data, dict):
        continue
    obj = data.get("object")
    if isinstance(obj, dict) and obj.get("id") == invoice_id:
        event_id = event.get("id")
        if isinstance(event_id, str) and event_id:
            print(event_id)
            raise SystemExit(0)
raise SystemExit(1)
PY
)"
    if [ -z "$CANARY_LIVE_PAYMENT_EVENT_ID" ]; then
        mark_failure "live_find_payment_event" "invoice.payment_succeeded event not found for ${CANARY_LIVE_INVOICE_ID}"
        return 1
    fi

    log "live payment event located (${CANARY_LIVE_PAYMENT_EVENT_ID})"
}

run_live_webhook_verify_step() {
    local max_attempts=15 attempt

    if [ -z "$ADMIN_KEY" ]; then
        mark_failure "live_webhook_verify" "ADMIN_KEY is required for /admin/webhook-events lookup"
        return 1
    fi
    if [ -z "$CANARY_LIVE_PAYMENT_EVENT_ID" ]; then
        mark_failure "live_webhook_verify" "CANARY_LIVE_PAYMENT_EVENT_ID missing before webhook verification"
        return 1
    fi

    for attempt in $(seq 1 "$max_attempts"); do
        capture_json_response admin_call GET "/admin/webhook-events?stripe_event_id=${CANARY_LIVE_PAYMENT_EVENT_ID}"
        if [ "$HTTP_RESPONSE_CODE" = "200" ]; then
            if python3 - "$HTTP_RESPONSE_BODY" "$CANARY_LIVE_PAYMENT_EVENT_ID" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
event_id = sys.argv[2]
if isinstance(payload, dict) and payload.get("stripe_event_id") == event_id:
    raise SystemExit(0)
raise SystemExit(1)
PY
            then
                log "webhook persistence verified (${CANARY_LIVE_PAYMENT_EVENT_ID})"
                return 0
            fi
        elif [ "$HTTP_RESPONSE_CODE" != "404" ]; then
            mark_failure "live_webhook_verify" "webhook lookup returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
            return 1
        fi
        sleep 2
    done

    mark_failure "live_webhook_verify" "webhook event ${CANARY_LIVE_PAYMENT_EVENT_ID} was not persisted within 30 seconds"
    return 1
}

run_live_cleanup_step() {
    if [ -n "$CANARY_LIVE_CHARGE_ID" ] && [ -z "$CANARY_LIVE_REFUND_ID" ]; then
        if stripe_request POST "/v1/refunds" \
            -d "charge=$CANARY_LIVE_CHARGE_ID" \
            -d "reason=requested_by_customer" \
            && [ "$STRIPE_HTTP_CODE" = "200" ]; then
            CANARY_LIVE_REFUND_ID="$(json_get_field "$STRIPE_BODY" "id")"
            log "cleanup refunded live charge (${CANARY_LIVE_CHARGE_ID})"
        else
            log "cleanup refund attempt failed for charge ${CANARY_LIVE_CHARGE_ID} (http=${STRIPE_HTTP_CODE:-unknown})"
        fi
    fi

    if [ -n "$CANARY_LIVE_INVOICE_ID" ] && [ -z "$CANARY_LIVE_CHARGE_ID" ]; then
        if stripe_request POST "/v1/invoices/${CANARY_LIVE_INVOICE_ID}/void" && [ "$STRIPE_HTTP_CODE" = "200" ]; then
            log "cleanup voided unpaid live invoice (${CANARY_LIVE_INVOICE_ID})"
        else
            log "cleanup void attempt failed for invoice ${CANARY_LIVE_INVOICE_ID} (http=${STRIPE_HTTP_CODE:-unknown})"
        fi
    fi
}

run_live_stripe_branch() {
    run_sync_stripe_step || return 1
    run_setup_intent_and_stripe_attach_step || return 1
    run_live_create_invoice_step || return 1
    run_live_find_payment_event_step || return 1
    run_live_refund_step || return 1
    run_live_webhook_verify_step || return 1
}

run_index_create_step() {
    CANARY_INDEX_NAME="canary-${CANARY_NONCE}"

    capture_json_response tenant_call POST "/indexes" "$CANARY_TOKEN" \
        -d "{\"name\":\"${CANARY_INDEX_NAME}\",\"region\":\"${CANARY_INDEX_REGION}\"}"
    if [ "$HTTP_RESPONSE_CODE" != "201" ] && [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        mark_failure "create_index" "create index returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    CANARY_INDEX_CREATED=1
    log "index created (${CANARY_INDEX_NAME})"
}

run_index_batch_step() {
    capture_json_response tenant_call POST "/indexes/${CANARY_INDEX_NAME}/batch" "$CANARY_TOKEN" \
        -d "{\"requests\":[{\"action\":\"addObject\",\"body\":{\"objectID\":\"canary-doc-1\",\"title\":\"Customer Loop Canary Document\",\"body\":\"${CANARY_NONCE}\"}}]}"
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        mark_failure "write_document" "batch write returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    log "index write succeeded (${CANARY_INDEX_NAME})"
}

run_index_search_step() {
    local search_ok=0 attempt

    for attempt in 1 2 3 4 5; do
        capture_json_response tenant_call POST "/indexes/${CANARY_INDEX_NAME}/search" "$CANARY_TOKEN" \
            -d "{\"query\":\"${CANARY_NONCE}\"}"
        if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
            sleep 1
            continue
        fi

        if python3 - "$HTTP_RESPONSE_BODY" <<'PY'
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
        -d '{"confirm":true}'
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

    if [ -z "$ADMIN_KEY" ]; then
        mark_failure "admin_cleanup" "ADMIN_KEY missing; cannot call DELETE /admin/tenants/{id}"
        return 1
    fi

    capture_json_response admin_call DELETE "/admin/tenants/${CANARY_CUSTOMER_ID}"
    if [ "$HTTP_RESPONSE_CODE" != "204" ] && [ "$HTTP_RESPONSE_CODE" != "404" ]; then
        mark_failure "admin_cleanup" "admin tenant cleanup returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    CANARY_ADMIN_CLEANED=1
    log "admin cleanup completed for tenant ${CANARY_CUSTOMER_ID}"
}

run_customer_loop() {
    run_signup_step || return 1
    run_verify_email_step || return 1
    if [ "$CANARY_LIVE_MODE" = "1" ]; then
        run_live_stripe_branch || return 1
    else
        log "CANARY_LIVE_MODE=${CANARY_LIVE_MODE}; skipping live Stripe branch"
    fi
    run_index_create_step || return 1
    run_index_batch_step || return 1
    run_index_search_step || return 1
    run_delete_index_step || return 1
    run_delete_account_step || return 1
    run_admin_cleanup_step || return 1
}

cleanup_after_flow() {
    run_live_cleanup_step || true
    run_delete_index_step || true
    run_delete_account_step || true
    run_admin_cleanup_step || true
}

main() {
    if ! parse_cli_args "$@"; then
        return 1
    fi
    if [ "$CANARY_SHOW_HELP" -eq 1 ]; then
        print_usage
        return 0
    fi

    load_canary_env
    if [ -n "$CANARY_LIVE_MODE_CLI_OVERRIDE" ]; then
        CANARY_LIVE_MODE="$CANARY_LIVE_MODE_CLI_OVERRIDE"
        export CANARY_LIVE_MODE
    fi
    if [ "$CANARY_LIVE_MODE" != "0" ] && [ "$CANARY_LIVE_MODE" != "1" ]; then
        echo "CANARY_LIVE_MODE must be 0 or 1 (got '${CANARY_LIVE_MODE}')" >&2
        return 1
    fi

    local rc_readiness_mode="${CANARY_RC_READINESS_MODE:-0}"

    if quiet_window_active; then
        if [ "$rc_readiness_mode" = "1" ]; then
            log "quiet window active, but CANARY_RC_READINESS_MODE=1 overrides short-circuit"
        else
            log "quiet window active; skipping customer loop execution"
            return 0
        fi
    fi

    if ! run_customer_loop; then
        log "customer loop failed before completion; entering cleanup"
    fi

    cleanup_after_flow

    if [ "$FLOW_FAILED" -eq 1 ]; then
        log "step '${FLOW_FAILURE_STEP}' failed: ${FLOW_FAILURE_DETAIL}"
        if [ "$rc_readiness_mode" = "1" ]; then
            log "CANARY_RC_READINESS_MODE=1 suppresses outbound failure alert dispatch"
        else
            dispatch_failure_alert "$FLOW_FAILURE_STEP" "$FLOW_FAILURE_DETAIL"
        fi
        return 1
    fi

    log "customer loop canary completed successfully"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
