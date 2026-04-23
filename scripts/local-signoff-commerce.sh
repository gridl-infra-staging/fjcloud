#!/usr/bin/env bash
# local-signoff-commerce.sh — Strict local commerce proof runner.
#
# Exercises the full local commerce lane: signup -> email verification ->
# batch billing -> invoice payment. Requires the strict local profile
# (STRIPE_LOCAL_MODE=1, real email verification via Mailpit, etc.).
#
# Emits machine-readable JSON evidence and operator-readable summary
# outside the repo tree for Stage 4 reuse.
#
# Usage:
#   ./scripts/local-signoff-commerce.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/validation_json.sh
source "$SCRIPT_DIR/lib/validation_json.sh"

# Local aliases for shared validation helpers (short names used throughout).
append_step() { validation_append_step "$@"; }
emit_result() { validation_emit_result "$@"; }
json_get_field() { validation_json_get_field "$@"; }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() { echo "[commerce-signoff] $*"; }
die() { echo "[commerce-signoff] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight: require strict signoff environment
# ---------------------------------------------------------------------------

require_strict_signoff_env() {
    local missing=()

    [ "${STRIPE_LOCAL_MODE:-}" = "1" ] || missing+=("STRIPE_LOCAL_MODE=1")
    [ -n "${MAILPIT_API_URL:-}" ]     || missing+=("MAILPIT_API_URL")
    [ -n "${STRIPE_WEBHOOK_SECRET:-}" ] || missing+=("STRIPE_WEBHOOK_SECRET")
    [ -n "${COLD_STORAGE_ENDPOINT:-}" ] || missing+=("COLD_STORAGE_ENDPOINT")
    [ -n "${FLAPJACK_REGIONS:-}" ]     || missing+=("FLAPJACK_REGIONS")

    if [ ${#missing[@]} -gt 0 ]; then
        die "Strict signoff requires: ${missing[*]}"
    fi

    if [ -n "${SKIP_EMAIL_VERIFICATION:-}" ]; then
        die "SKIP_EMAIL_VERIFICATION must be unset for strict signoff (found: $SKIP_EMAIL_VERIFICATION)"
    fi

    API_URL="${API_URL:-http://localhost:3001}"
    ADMIN_KEY="${ADMIN_KEY:-}"

    if ! curl -sf "${API_URL}/health" >/dev/null 2>&1; then
        die "API health check failed at ${API_URL}/health"
    fi

    log "Preflight passed: strict signoff environment verified"
}

# ---------------------------------------------------------------------------
# Artifact directory
# ---------------------------------------------------------------------------

ARTIFACT_DIR=""
SEED_USER_EMAIL="${SEED_USER_EMAIL:-dev@example.com}"
SEED_USER_PASSWORD="${SEED_USER_PASSWORD:-localdev-password-1234}"
SHARED_USER_TOKEN=""
SHARED_USER_CUSTOMER_ID=""
BATCH_BILLING_MONTH=""

init_artifact_dir() {
    ARTIFACT_DIR="${TMPDIR:-/tmp}/fjcloud-commerce-signoff"
    mkdir -p "$ARTIFACT_DIR"
    log "Artifact directory: $ARTIFACT_DIR"
}

# ---------------------------------------------------------------------------
# Commerce proof helpers
# ---------------------------------------------------------------------------

# Kept overridable so tests can inject a fixture seed script without editing this
# runner. Production/local runs still default to scripts/seed_local.sh.
SEED_LOCAL_SCRIPT="${SEED_LOCAL_SCRIPT:-$REPO_ROOT/scripts/seed_local.sh}"

api_json_call() {
    local method="$1" path="$2"
    shift 2
    curl -sS -X "$method" "${API_URL}${path}" \
        -H "Content-Type: application/json" \
        "$@"
}

admin_call() {
    local method="$1" path="$2"
    shift 2
    api_json_call "$method" "$path" \
        -H "x-admin-key: ${ADMIN_KEY}" \
        "$@"
}

tenant_call() {
    local method="$1" path="$2" token="$3"
    shift 3
    api_json_call "$method" "$path" \
        -H "Authorization: Bearer ${token}" \
        "$@"
}

HTTP_RESPONSE_BODY=""
HTTP_RESPONSE_CODE=""

capture_json_response() {
    local response
    response=$("$@" -w "\n%{http_code}" 2>/dev/null) || true
    HTTP_RESPONSE_CODE=$(echo "$response" | tail -1)
    HTTP_RESPONSE_BODY=$(echo "$response" | sed '$d')
}

run_seed_twice() {
    log "Running seed_local.sh (pass 1)..."
    bash "$SEED_LOCAL_SCRIPT" >/dev/null 2>&1 \
        || { append_step "seed_pass_1" false "seed_local.sh pass 1 failed"; return 1; }
    append_step "seed_pass_1" true "seed_local.sh pass 1 completed"

    log "Running seed_local.sh (pass 2 — idempotency check)..."
    bash "$SEED_LOCAL_SCRIPT" >/dev/null 2>&1 \
        || { append_step "seed_pass_2" false "seed_local.sh pass 2 failed"; return 1; }
    append_step "seed_pass_2" true "seed_local.sh pass 2 completed (idempotent)"
}

login_seeded_shared_user() {
    capture_json_response api_json_call POST "/auth/login" \
        -d "{\"email\":\"${SEED_USER_EMAIL}\",\"password\":\"${SEED_USER_PASSWORD}\"}"

    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        append_step "seeded_shared_login" false \
            "Seeded shared user login returned HTTP $HTTP_RESPONSE_CODE"
        return 1
    fi

    SHARED_USER_TOKEN=$(json_get_field "$HTTP_RESPONSE_BODY" "token")
    SHARED_USER_CUSTOMER_ID=$(json_get_field "$HTTP_RESPONSE_BODY" "customer_id")
    if [ -z "$SHARED_USER_TOKEN" ] || [ -z "$SHARED_USER_CUSTOMER_ID" ]; then
        append_step "seeded_shared_login" false \
            "Seeded shared user login returned incomplete auth response"
        return 1
    fi

    log "Seeded shared user authenticated: ${SEED_USER_EMAIL} (${SHARED_USER_CUSTOMER_ID})"
    append_step "seeded_shared_login" true \
        "Authenticated ${SEED_USER_EMAIL}"
}

assert_seeded_customer_stripe_linked() {
    local customer_id="$1" user_email="$2"
    local stripe_customer_id

    capture_json_response admin_call POST "/admin/customers/${customer_id}/sync-stripe"

    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        append_step "stripe_link_verified" false \
            "Stripe sync for $user_email returned HTTP $HTTP_RESPONSE_CODE"
        return 1
    fi

    stripe_customer_id=$(json_get_field "$HTTP_RESPONSE_BODY" "stripe_customer_id")
    if [ -z "$stripe_customer_id" ]; then
        append_step "stripe_link_verified" false \
            "No stripe_customer_id for $user_email"
        return 1
    fi

    log "Stripe link verified for $user_email: $stripe_customer_id"
    append_step "stripe_link_verified" true \
        "$user_email linked as $stripe_customer_id"
}

register_fresh_signup() {
    local email="$1"

    capture_json_response api_json_call POST "/auth/register" \
        -d "{\"name\":\"Local Commerce Signoff\",\"email\":\"$email\",\"password\":\"signoff-test-pass-1234\"}"

    if [ "$HTTP_RESPONSE_CODE" != "201" ] && [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        append_step "fresh_signup" false \
            "Registration for $email failed with HTTP $HTTP_RESPONSE_CODE"
        return 1
    fi

    SIGNUP_TOKEN=$(json_get_field "$HTTP_RESPONSE_BODY" "token")
    log "Registered $email"
    append_step "fresh_signup_register" true "Registered $email"
}

verify_signup_via_mailpit() {
    local email="$1"
    local max_attempts=10 attempt=0

    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))

        local messages
        messages=$(curl -sS "${MAILPIT_API_URL}/api/v1/search?query=to:${email}" 2>/dev/null) || true
        local count
        count=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("messages_count",d.get("total",0)))' "$messages" 2>/dev/null || echo "0")

        if [ "$count" -le 0 ]; then sleep 1; continue; fi

        local message_id
        message_id=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["messages"][0]["ID"])' "$messages" 2>/dev/null || true)
        if [ -z "$message_id" ]; then sleep 1; continue; fi

        local msg_body
        msg_body=$(curl -sS "${MAILPIT_API_URL}/api/v1/message/${message_id}" 2>/dev/null) || true
        local verify_token
        verify_token=$(python3 -c '
import json, sys, re
msg = json.loads(sys.argv[1])
text = msg.get("Text","") + msg.get("HTML","")
m = re.search(r"verify-email[?&]token=([A-Za-z0-9_-]+)", text)
if m: print(m.group(1))
else: print("")
' "$msg_body" 2>/dev/null || true)
        if [ -z "$verify_token" ]; then sleep 1; continue; fi

        local verify_response verify_code
        verify_response=$(curl -sS -w "\n%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "{\"token\":\"$verify_token\"}" \
            "${API_URL}/auth/verify-email" 2>/dev/null) || true
        verify_code=$(echo "$verify_response" | tail -1)

        if [ "$verify_code" = "200" ] || [ "$verify_code" = "204" ]; then
            log "Email verified for $email"
            append_step "verify_signup_email" true \
                "Verified $email via Mailpit token"
            return 0
        fi
        append_step "verify_signup_email" false \
            "Verify-email call returned HTTP $verify_code"
        return 1
    done

    append_step "verify_signup_email" false \
        "No verification email found for $email after ${max_attempts}s"
    return 1
}

run_local_batch_billing() {
    local billing_month
    # Defaults to the current UTC month so repeated local signoff runs have a
    # deterministic target unless the operator pins SIGNOFF_MONTH explicitly.
    # Reruns against an already-billed month can surface already_invoiced in the
    # per-customer results while the overall endpoint call still succeeds.
    billing_month="${SIGNOFF_MONTH:-$(date -u +%Y-%m)}"
    BATCH_BILLING_MONTH="$billing_month"

    capture_json_response admin_call POST "/admin/billing/run" \
        -d "{\"month\":\"${billing_month}\"}"

    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        append_step "batch_billing" false \
            "Batch billing returned HTTP $HTTP_RESPONSE_CODE"
        return 1
    fi

    BATCH_RESULT="$HTTP_RESPONSE_BODY"
    local invoices_created
    invoices_created=$(json_get_field "$HTTP_RESPONSE_BODY" "invoices_created")
    log "Batch billing complete for ${billing_month}: $invoices_created invoices created"
    append_step "batch_billing" true \
        "Created $invoices_created invoices for ${billing_month}"
}

wait_for_invoice_paid() {
    local invoice_id="$1" user_token="$2"
    local max_attempts=15 attempt=0

    while [ $attempt -lt $max_attempts ]; do
        local status paid_at
        capture_json_response tenant_call GET "/invoices/${invoice_id}" "$user_token"

        if [ "$HTTP_RESPONSE_CODE" = "200" ]; then
            status=$(json_get_field "$HTTP_RESPONSE_BODY" "status")
            paid_at=$(json_get_field "$HTTP_RESPONSE_BODY" "paid_at")
            if [ "$status" = "paid" ] && [ -n "$paid_at" ]; then
                log "Invoice $invoice_id is paid (paid_at: $paid_at)"
                append_step "invoice_paid" true \
                    "Invoice $invoice_id paid at $paid_at"
                return 0
            fi
        fi

        attempt=$((attempt + 1))
        sleep 1
    done

    append_step "invoice_paid" false \
        "Invoice $invoice_id not paid after ${max_attempts}s (status: ${status:-unknown})"
    return 1
}

check_mailpit_invoice_email() {
    local email="$1"
    local max_attempts=10 attempt=0

    while [ $attempt -lt $max_attempts ]; do
        local messages
        messages=$(curl -sS "${MAILPIT_API_URL}/api/v1/search?query=to:${email}+subject:invoice" 2>/dev/null) || true
        local count
        count=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("messages_count",d.get("total",0)))' "$messages" 2>/dev/null || echo "0")

        if [ "$count" -gt 0 ]; then
            log "Invoice email found for $email"
            append_step "mailpit_invoice_email" true \
                "Invoice email captured for $email"
            return 0
        fi

        attempt=$((attempt + 1))
        sleep 1
    done

    append_step "mailpit_invoice_email" false \
        "No invoice email for $email after ${max_attempts}s"
    return 1
}

batch_created_invoice_for_customer() {
    local batch_json="$1" customer_id="$2"
    python3 - "$batch_json" "$customer_id" <<'PY' || true
import json
import sys

data = json.loads(sys.argv[1])
target_customer_id = sys.argv[2]
for result in data.get("results", []):
    if result.get("customer_id") != target_customer_id:
        continue
    if result.get("status") == "created" and result.get("invoice_id"):
        print(result["invoice_id"])
        break
PY
}

batch_customer_already_invoiced() {
    local batch_json="$1" customer_id="$2"
    python3 - "$batch_json" "$customer_id" <<'PY' || true
import json
import sys

data = json.loads(sys.argv[1])
target_customer_id = sys.argv[2]
for result in data.get("results", []):
    if result.get("customer_id") != target_customer_id:
        continue
    if result.get("status") == "skipped" and result.get("reason") == "already_invoiced":
        print("true")
        break
PY
}

existing_invoice_for_month() {
    local user_token="$1" billing_month="$2"

    capture_json_response tenant_call GET "/invoices" "$user_token"
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        return 1
    fi

    python3 - "$HTTP_RESPONSE_BODY" "$billing_month" <<'PY' || true
import json
import sys

invoices = json.loads(sys.argv[1])
billing_month = sys.argv[2]
period_start = f"{billing_month}-01"
for invoice in invoices:
    if invoice.get("period_start") == period_start:
        print(invoice.get("id", ""))
        break
PY
}

# ---------------------------------------------------------------------------
# Evidence writing
# ---------------------------------------------------------------------------

write_run_artifacts() {
    local passed="$1"
    local timestamp
    timestamp="$(date -u +%Y-%m-%d_%H%M%S)"
    local json_file="$ARTIFACT_DIR/commerce_signoff_${timestamp}.json"
    local txt_file="$ARTIFACT_DIR/commerce_signoff_${timestamp}.txt"

    emit_result "$passed" > "$json_file"

    {
        echo "Commerce Signoff — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Result: $([ "$passed" = "true" ] && echo "PASSED" || echo "FAILED")"
        echo "Evidence: $json_file"
        echo ""
        echo "Steps:"
        python3 -c '
import json, sys
data = json.loads(sys.argv[1])
for s in data.get("steps", []):
    mark = "PASS" if s["passed"] else "FAIL"
    print("  [{}] {}: {}".format(mark, s["name"], s["detail"]))
' "$(cat "$json_file")" 2>/dev/null || echo "  (could not parse steps)"
    } > "$txt_file"

    log "JSON evidence: $json_file" >&2
    log "Operator summary: $txt_file" >&2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "Starting strict local commerce proof..."

    require_strict_signoff_env
    append_step "require_strict_env" true "Strict signoff environment verified"

    init_artifact_dir

    local overall_passed=true

    # Step 1: Seed twice (idempotency proof)
    if ! run_seed_twice; then
        overall_passed=false
        write_run_artifacts false
        return 1
    fi

    # Step 2: Log into the seeded shared user and verify Stripe linkage through
    # the existing idempotent admin sync endpoint.
    if ! login_seeded_shared_user; then
        overall_passed=false
    elif ! assert_seeded_customer_stripe_linked "$SHARED_USER_CUSTOMER_ID" "$SEED_USER_EMAIL"; then
        overall_passed=false
    fi

    # Step 3: Fresh signup with email verification
    local fresh_email="signoff-$(date +%s)@commerce-test.local"
    if ! register_fresh_signup "$fresh_email"; then
        overall_passed=false
    else
        if ! verify_signup_via_mailpit "$fresh_email"; then
            overall_passed=false
        fi
    fi

    # Step 4: Batch billing
    if ! run_local_batch_billing; then
        overall_passed=false
    else
        # Step 5: Wait for invoice payment
        local shared_invoice_id
        shared_invoice_id=$(batch_created_invoice_for_customer "$BATCH_RESULT" "$SHARED_USER_CUSTOMER_ID")

        if [ -n "$shared_invoice_id" ]; then
            if ! wait_for_invoice_paid "$shared_invoice_id" "$SHARED_USER_TOKEN"; then
                overall_passed=false
            fi
        else
            local already_invoiced existing_invoice_id
            already_invoiced=$(batch_customer_already_invoiced "$BATCH_RESULT" "$SHARED_USER_CUSTOMER_ID")
            if [ "$already_invoiced" = "true" ]; then
                existing_invoice_id=$(existing_invoice_for_month "$SHARED_USER_TOKEN" "$BATCH_BILLING_MONTH")
                if [ -n "$existing_invoice_id" ]; then
                    log "Batch billing skipped ${SEED_USER_EMAIL} because ${BATCH_BILLING_MONTH} is already invoiced; verifying existing invoice ${existing_invoice_id}"
                    if ! wait_for_invoice_paid "$existing_invoice_id" "$SHARED_USER_TOKEN"; then
                        overall_passed=false
                    fi
                else
                    append_step "invoice_paid" false \
                        "Batch result reported already_invoiced for ${SEED_USER_EMAIL}, but no ${BATCH_BILLING_MONTH} invoice was visible to the tenant"
                    overall_passed=false
                fi
            else
                append_step "invoice_paid" false \
                    "No created invoice found in batch result for ${SEED_USER_EMAIL}"
                overall_passed=false
            fi
        fi
    fi

    # Step 6: Check for Mailpit invoice email
    if ! check_mailpit_invoice_email "$SEED_USER_EMAIL"; then
        overall_passed=false
    fi

    write_run_artifacts "$overall_passed"

    if [ "$overall_passed" = "true" ]; then
        log "Commerce signoff PASSED"
    else
        log "Commerce signoff FAILED"
        return 1
    fi
}

main
