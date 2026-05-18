#!/usr/bin/env bash
# Shared customer lifecycle steps reused by canary and VM lifecycle orchestrator.
#
# Caller-owned prerequisites:
# - log function
# - flow globals: FLOW_FAILED, FLOW_FAILURE_STEP, FLOW_FAILURE_DETAIL
# - HTTP seams from scripts/lib/http_json.sh
# - inbox seams from scripts/lib/test_inbox_helpers.sh for verify-email
# - env vars/state variables used below (CANARY_* namespace)

mark_failure() {
    local step_name="$1"
    local detail_message="$2"

    if [ "${FLOW_FAILED:-0}" -eq 0 ]; then
        FLOW_FAILED=1
        FLOW_FAILURE_STEP="$step_name"
        FLOW_FAILURE_DETAIL="$detail_message"
    fi
}

json_get_field() {
    local json_body="$1"
    local field_name="$2"

    python3 - "$json_body" "$field_name" <<PY || true
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

generate_customer_signup_password() {
    python3 - <<PY
import secrets

print(f"Canary-{secrets.token_hex(16)}")
PY
}

# Backward-compatible alias used by customer_loop_synthetic.sh.
generate_canary_signup_password() {
    generate_customer_signup_password
}

run_signup_step() {
    CANARY_NONCE="canary$(date -u +%Y%m%d%H%M%S)${RANDOM}"
    CANARY_SIGNUP_EMAIL="canary+${CANARY_NONCE}@${CANARY_TEST_INBOX_DOMAIN}"
    CANARY_SIGNUP_PASSWORD="$(generate_customer_signup_password)"

    capture_json_response api_json_call POST "/auth/register" \
        -d "{\"name\":\"Staging Customer Canary\",\"email\":\"${CANARY_SIGNUP_EMAIL}\",\"password\":\"${CANARY_SIGNUP_PASSWORD}\"}"

    if [ "${HTTP_RESPONSE_CODE:-}" != "201" ] && [ "${HTTP_RESPONSE_CODE:-}" != "200" ]; then
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
    if [ "${HTTP_RESPONSE_CODE:-}" != "200" ] && [ "${HTTP_RESPONSE_CODE:-}" != "204" ]; then
        mark_failure "verify_email" "verify-email returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi

    log "email verification succeeded for ${CANARY_SIGNUP_EMAIL}"
}
