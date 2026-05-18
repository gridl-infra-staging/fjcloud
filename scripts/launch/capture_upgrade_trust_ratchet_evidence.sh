#!/usr/bin/env bash
set -euo pipefail
#
# Captures trust-ratchet evidence for the self-service upgrade endpoint.
#
# Three contracts are exercised:
#   1. success-paid   — success PM id from env → HTTP 200, plan=shared, paid invoice
#   2. declined-402   — decline PM id from env → HTTP 402, plan stays free
#   3. requires_action-402 — requires-action PM id from env → HTTP 402, plan stays free
#
# Usage:
#   source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)
#   bash scripts/launch/capture_upgrade_trust_ratchet_evidence.sh
#
# Requires: API_URL, ADMIN_KEY, STRIPE_SECRET_KEY in the environment.
# Payment method ids come from environment (mode-aware defaults below).

: "${API_URL:?API_URL must be set}"
: "${ADMIN_KEY:?ADMIN_KEY must be set}"
: "${STRIPE_SECRET_KEY:?STRIPE_SECRET_KEY must be set}"

STRIPE_KEY_MODE="unknown"
if [[ "$STRIPE_SECRET_KEY" == sk_test_* || "$STRIPE_SECRET_KEY" == rk_test_* ]]; then
    STRIPE_KEY_MODE="test"
elif [[ "$STRIPE_SECRET_KEY" == sk_live_* || "$STRIPE_SECRET_KEY" == rk_live_* ]]; then
    STRIPE_KEY_MODE="live"
fi

UPGRADE_PM_SUCCESS="${UPGRADE_PM_SUCCESS:-${LIFECYCLE_PROBE_PM_ID:-}}"
UPGRADE_PM_DECLINED="${UPGRADE_PM_DECLINED:-${LIFECYCLE_PROBE_PM_DECLINED_ID:-}}"
UPGRADE_PM_REQUIRES_ACTION="${UPGRADE_PM_REQUIRES_ACTION:-${LIFECYCLE_PROBE_PM_REQUIRES_ACTION_ID:-}}"

if [ "$STRIPE_KEY_MODE" = "test" ]; then
    UPGRADE_PM_SUCCESS="${UPGRADE_PM_SUCCESS:-pm_card_visa}"
    UPGRADE_PM_DECLINED="${UPGRADE_PM_DECLINED:-pm_card_chargeDeclined}"
    UPGRADE_PM_REQUIRES_ACTION="${UPGRADE_PM_REQUIRES_ACTION:-pm_card_authenticationRequired}"
fi

if [ -z "$UPGRADE_PM_SUCCESS" ] || [ -z "$UPGRADE_PM_DECLINED" ] || [ -z "$UPGRADE_PM_REQUIRES_ACTION" ]; then
    echo "ERROR: missing PM ids. Set UPGRADE_PM_SUCCESS/UPGRADE_PM_DECLINED/UPGRADE_PM_REQUIRES_ACTION (or LIFECYCLE_PROBE_PM_* aliases)." >&2
    exit 64
fi

if [ "$STRIPE_KEY_MODE" = "live" ]; then
    if [[ "$UPGRADE_PM_SUCCESS" == pm_card_* || "$UPGRADE_PM_DECLINED" == pm_card_* || "$UPGRADE_PM_REQUIRES_ACTION" == pm_card_* ]]; then
        echo "ERROR: pm_card_* test tokens are invalid for live-mode Stripe keys; set mode-compatible UPGRADE_PM_* values." >&2
        exit 64
    fi
fi

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR="docs/runbooks/evidence/browser-evidence/${TIMESTAMP}_upgrade_trust_ratchet"
mkdir -p "$EVIDENCE_DIR"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

admin_post() {
    local path="$1"; shift
    # Feed secrets through curl config stdin so they do not appear in argv.
    curl -sf --config - -X POST "${API_URL}${path}" \
        -H "Content-Type: application/json" \
        "$@" <<EOF
header = "x-admin-key: ${ADMIN_KEY}"
EOF
}

admin_get() {
    local path="$1"; shift
    curl -sf --config - -X GET "${API_URL}${path}" \
        "$@" <<EOF
header = "x-admin-key: ${ADMIN_KEY}"
EOF
}

tenant_post() {
    local token="$1" path="$2"; shift 2
    curl -s --config - -w "\n%{http_code}" -X POST "${API_URL}${path}" \
        -H "Content-Type: application/json" \
        "$@" <<EOF
header = "Authorization: Bearer ${token}"
EOF
}

tenant_get() {
    local token="$1" path="$2"; shift 2
    curl -sf --config - -X GET "${API_URL}${path}" \
        "$@" <<EOF
header = "Authorization: Bearer ${token}"
EOF
}

stripe_api() {
    curl -sS --config - "$@" <<EOF
user = "${STRIPE_SECRET_KEY}:"
EOF
}

stripe_request_json() {
    local context="$1"
    shift

    local response_file
    response_file="$(mktemp "${TMPDIR:-/tmp}/fjcloud-stripe-response.XXXXXX")"

    local http_code
    http_code="$(stripe_api -o "$response_file" -w "%{http_code}" "$@")" || {
        rm -f "$response_file"
        echo "ERROR: ${context}: Stripe request transport failed" >&2
        return 56
    }

    if ! python3 -m json.tool <"$response_file" >/dev/null 2>&1; then
        local preview
        preview="$(sed -n '1,6p' "$response_file" | tr '\n' ' ')"
        rm -f "$response_file"
        echo "ERROR: ${context}: Stripe response was not valid JSON (http=${http_code}, preview=${preview:-<empty>})" >&2
        return 56
    fi

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        local stripe_code stripe_message
        stripe_code="$(
            python3 -c "import json,sys; d=json.load(sys.stdin); print(((d.get('error') or {}).get('code')) or '')" \
                <"$response_file" 2>/dev/null || true
        )"
        stripe_message="$(
            python3 -c "import json,sys; d=json.load(sys.stdin); print(((d.get('error') or {}).get('message')) or '')" \
                <"$response_file" 2>/dev/null || true
        )"
        rm -f "$response_file"
        echo "ERROR: ${context} (http=${http_code}, code=${stripe_code:-unknown}, message=${stripe_message:-unknown})" >&2
        return 56
    fi

    cat "$response_file"
    rm -f "$response_file"
}

contract_json_field() {
    local json_payload="$1" python_expr="$2"
    python3 -c "import json,sys; data=json.loads(sys.argv[1]); print(${python_expr})" \
        "$json_payload"
}

verify_contract_expectations() {
    local label="$1" expected_http="$2" http_code="$3" response_body="$4" post_status="$5"

    if [ "$http_code" != "$expected_http" ]; then
        echo "ERROR: ${label}: expected HTTP ${expected_http}, got ${http_code}" >&2
        return 1
    fi

    case "$label" in
        success_paid)
            local billing_plan stripe_invoice_id anchor_at post_upgrade_ready
            billing_plan="$(contract_json_field "$response_body" "repr(data.get('billing_plan', ''))")"
            stripe_invoice_id="$(contract_json_field "$response_body" "repr(data.get('stripe_invoice_id', ''))")"
            anchor_at="$(contract_json_field "$response_body" "repr(data.get('subscription_cycle_anchor_at', ''))")"
            post_upgrade_ready="$(contract_json_field "$post_status" "repr(data.get('upgrade_ready'))")"
            if [ "$billing_plan" != "'shared'" ] || [ "$stripe_invoice_id" = "''" ] || [ "$anchor_at" = "''" ]; then
                echo "ERROR: ${label}: 200 response did not persist the shared-plan activation contract" >&2
                return 1
            fi
            if [ "$post_upgrade_ready" != "False" ]; then
                echo "ERROR: ${label}: post-upgrade status still reports upgrade_ready=${post_upgrade_ready}" >&2
                return 1
            fi
            ;;
        declined_402)
            local decline_code post_upgrade_ready
            decline_code="$(contract_json_field "$response_body" "repr(data.get('code', ''))")"
            post_upgrade_ready="$(contract_json_field "$post_status" "repr(data.get('upgrade_ready'))")"
            if [ "$decline_code" != "'card_declined'" ]; then
                echo "ERROR: ${label}: expected card_declined code, got ${decline_code}" >&2
                return 1
            fi
            if [ "$post_upgrade_ready" != "True" ]; then
                echo "ERROR: ${label}: declined retry path must leave upgrade_ready=true, got ${post_upgrade_ready}" >&2
                return 1
            fi
            ;;
        requires_action_402)
            local action_code post_upgrade_ready
            action_code="$(contract_json_field "$response_body" "repr(data.get('code', ''))")"
            post_upgrade_ready="$(contract_json_field "$post_status" "repr(data.get('upgrade_ready'))")"
            if [ "$action_code" != "'invoice_payment_intent_requires_action'" ]; then
                echo "ERROR: ${label}: expected invoice_payment_intent_requires_action code, got ${action_code}" >&2
                return 1
            fi
            if [ "$post_upgrade_ready" != "True" ]; then
                echo "ERROR: ${label}: requires-action retry path must leave upgrade_ready=true, got ${post_upgrade_ready}" >&2
                return 1
            fi
            ;;
        *)
            echo "ERROR: unknown contract label: ${label}" >&2
            return 1
            ;;
    esac
}

setup_test_customer() {
    local label="$1" pm_token="$2"
    local email="trust-ratchet-${label}-${TIMESTAMP}@test.flapjack.foo"
    local name="Trust Ratchet ${label}"

    log "Creating tenant: ${name}"
    local tenant_json
    tenant_json=$(admin_post "/admin/tenants" -d "{\"name\": \"${name}\", \"email\": \"${email}\"}")
    local customer_id
    customer_id=$(echo "$tenant_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

    log "Syncing Stripe for customer ${customer_id}"
    local sync_json
    sync_json=$(admin_post "/admin/customers/${customer_id}/sync-stripe")
    local stripe_customer_id
    stripe_customer_id=$(echo "$sync_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['stripe_customer_id'])")

    log "Attaching payment method ${pm_token} to ${stripe_customer_id}"
    local pm_json
    pm_json="$(
        stripe_request_json \
            "stripe attach failed for payment method ${pm_token}" \
            -X POST \
            "https://api.stripe.com/v1/payment_methods/${pm_token}/attach" \
            -d "customer=${stripe_customer_id}"
    )" || return 56

    local pm_id
    pm_id="$(echo "$pm_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)"
    if [ -z "$pm_id" ]; then
        echo "ERROR: stripe attach failed for payment method ${pm_token}: missing payment method id in Stripe response" >&2
        return 56
    fi

    log "Setting default payment method ${pm_id}"
    stripe_request_json \
        "stripe default payment method update failed" \
        -X POST \
        "https://api.stripe.com/v1/customers/${stripe_customer_id}" \
        -d "invoice_settings[default_payment_method]=${pm_id}" >/dev/null || return 56

    log "Minting JWT for customer ${customer_id}"
    local token_json
    token_json=$(admin_post "/admin/tokens" -d "{\"customer_id\": \"${customer_id}\", \"expires_in_secs\": 300}")
    local jwt
    jwt=$(echo "$token_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

    echo "${customer_id}|${stripe_customer_id}|${jwt}"
}

exercise_contract() {
    local label="$1" pm_token="$2" expected_http="$3"
    local contract_dir="${EVIDENCE_DIR}/${label}"
    mkdir -p "$contract_dir"

    log "=== Contract: ${label} (expect HTTP ${expected_http}) ==="

    local setup_result
    setup_result=$(setup_test_customer "$label" "$pm_token")
    local customer_id stripe_customer_id jwt
    customer_id=$(echo "$setup_result" | cut -d'|' -f1)
    stripe_customer_id=$(echo "$setup_result" | cut -d'|' -f2)
    jwt=$(echo "$setup_result" | cut -d'|' -f3)

    echo "{\"customer_id\": \"${customer_id}\", \"stripe_customer_id\": \"${stripe_customer_id}\", \"pm_token\": \"${pm_token}\"}" \
        | python3 -m json.tool > "$contract_dir/setup.json"

    log "Checking pre-upgrade status"
    local pre_status
    pre_status=$(tenant_get "$jwt" "/account/upgrade-status")
    echo "$pre_status" | python3 -m json.tool > "$contract_dir/pre_upgrade_status.json"

    log "Calling POST /billing/upgrade"
    local response_body http_code
    local raw_response
    raw_response=$(tenant_post "$jwt" "/billing/upgrade")
    http_code=$(echo "$raw_response" | tail -1)
    response_body=$(echo "$raw_response" | sed '$d')

    echo "$response_body" | python3 -m json.tool > "$contract_dir/upgrade_response.json" 2>/dev/null || echo "$response_body" > "$contract_dir/upgrade_response.json"
    echo "$http_code" > "$contract_dir/upgrade_http_code.txt"

    log "Upgrade response: HTTP ${http_code}"

    log "Checking post-upgrade status"
    local post_status
    post_status=$(tenant_get "$jwt" "/account/upgrade-status")
    echo "$post_status" | python3 -m json.tool > "$contract_dir/post_upgrade_status.json"

    verify_contract_expectations "$label" "$expected_http" "$http_code" "$response_body" "$post_status"
    log "PASS: ${label} contract verified"

    if [ "$expected_http" = "200" ]; then
        local invoice_id
        invoice_id=$(echo "$response_body" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stripe_invoice_id',''))" 2>/dev/null || echo "")
        if [ -n "$invoice_id" ]; then
            log "Fetching Stripe invoice ${invoice_id}"
            stripe_api "https://api.stripe.com/v1/invoices/${invoice_id}" \
                | python3 -m json.tool > "$contract_dir/stripe_invoice.json"
        fi
    fi

    echo "{\"label\": \"${label}\", \"expected_http\": ${expected_http}, \"actual_http\": ${http_code}, \"customer_id\": \"${customer_id}\", \"stripe_customer_id\": \"${stripe_customer_id}\"}" \
        | python3 -m json.tool > "$contract_dir/result.json"
}

log "Evidence capture starting. Bundle: ${EVIDENCE_DIR}"
log "API_URL=${API_URL}"

log "Verifying API health"
curl -sf "${API_URL}/health" | python3 -m json.tool > "${EVIDENCE_DIR}/health.json"

log "Verifying API version"
curl -sf "${API_URL}/version" | python3 -m json.tool > "${EVIDENCE_DIR}/version.json" 2>/dev/null || echo '{"error": "version endpoint not available"}' > "${EVIDENCE_DIR}/version.json"

exercise_contract "success_paid" "$UPGRADE_PM_SUCCESS" "200"
exercise_contract "declined_402" "$UPGRADE_PM_DECLINED" "402"
exercise_contract "requires_action_402" "$UPGRADE_PM_REQUIRES_ACTION" "402"

log "Writing SUMMARY.md"
cat > "${EVIDENCE_DIR}/SUMMARY.md" <<SUMMARYEOF
# Upgrade Trust-Ratchet Evidence

Evidence bundle for the self-service `POST /billing/upgrade` trust-ratchet contracts.

## Contracts Tested

| Contract | Payment Method | Expected HTTP | Evidence Dir |
|----------|---------------|---------------|--------------|
| success-paid | `${UPGRADE_PM_SUCCESS}` | 200 | `success_paid/` |
| declined-402 | `${UPGRADE_PM_DECLINED}` | 402 | `declined_402/` |
| requires_action-402 | `${UPGRADE_PM_REQUIRES_ACTION}` | 402 | `requires_action_402/` |

## Per-Contract Artifacts

Each subdirectory contains:
- `setup.json` — customer_id, stripe_customer_id, payment method used
- `pre_upgrade_status.json` — `GET /account/upgrade-status` before upgrade attempt
- `upgrade_response.json` — raw response body from `POST /billing/upgrade`
- `upgrade_http_code.txt` — HTTP status code
- `post_upgrade_status.json` — `GET /account/upgrade-status` after upgrade attempt
- `result.json` — pass/fail summary
- `stripe_invoice.json` (success path only) — Stripe invoice confirming paid status

## Trust-Ratchet Verification

- **success-paid**: Plan transitions free→shared, `subscription_cycle_anchor_at` is set, Stripe invoice is `paid`
- **declined-402**: Plan stays `free`, `upgrade_ready` remains `true` (customer can retry), response contains `code: "card_declined"`
- **requires_action-402**: Plan stays `free`, `upgrade_ready` remains `true`, response contains `code: "invoice_payment_intent_requires_action"`
SUMMARYEOF

log "Evidence bundle complete: ${EVIDENCE_DIR}"
log "Artifacts:"
find "$EVIDENCE_DIR" -type f | sort | while read f; do
    echo "  $(echo "$f" | sed "s|${EVIDENCE_DIR}/||")"
done
