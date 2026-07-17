#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/clickthrough_probe_common.sh"

EXIT_USAGE=2
EXIT_PRECONDITION=3
EXIT_RUNTIME=1

usage() {
    cat <<'USAGE'
Usage: bash scripts/probe_password_reset_clickthrough_e2e.sh <env-file>
   or: bash scripts/probe_password_reset_clickthrough_e2e.sh --env-file <path>
USAGE
}

usage_fail() {
    echo "ERROR: $1" >&2
    usage >&2
    exit "$EXIT_USAGE"
}

precondition_fail() {
    echo "ERROR: $1" >&2
    exit "$EXIT_PRECONDITION"
}

runtime_fail() {
    echo "ERROR: $1" >&2
    exit "$EXIT_RUNTIME"
}

reset_token_poll_until_cleared() {
    local probe_email="$1"
    local token_cleared_sql="$2"
    local max_attempts="$3"
    local sleep_seconds="$4"
    local attempt=1
    local token_cleared=""

    while [[ "$attempt" -le "$max_attempts" ]]; do
        token_cleared="$(probe_trim "$(probe_sql_single_value "$token_cleared_sql" 2>&1)")" || runtime_fail "failed validating reset token consumption for $probe_email"
        if [[ "$token_cleared" == "cleared" ]]; then
            echo "$attempt"
            return 0
        fi

        if [[ "$attempt" -lt "$max_attempts" && "$sleep_seconds" -gt 0 ]]; then
            sleep "$sleep_seconds"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

env_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)
            [[ $# -ge 2 ]] || usage_fail "--env-file requires a value"
            env_file="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            if [[ -z "$env_file" ]]; then
                env_file="$1"
                shift
            else
                usage_fail "unsupported argument '$1'"
            fi
            ;;
    esac
done

[[ -n "$env_file" ]] || usage_fail "env file is required"
[[ -f "$env_file" ]] || precondition_fail "env file not found: $env_file"

probe_env_file_maybe_load "$env_file"

api_url="$(probe_required_env_value API_URL 2>/dev/null || true)"
ses_from_address="$(probe_required_env_value SES_FROM_ADDRESS 2>/dev/null || true)"
ses_region="$(probe_required_env_value SES_REGION 2>/dev/null || true)"

[[ -n "$api_url" ]] || precondition_fail "API_URL is required"
[[ -n "$ses_from_address" ]] || precondition_fail "SES_FROM_ADDRESS is required"
[[ -n "$ses_region" ]] || precondition_fail "SES_REGION is required"

nonce="resetprobe$(date -u +%Y%m%d%H%M%S)${RANDOM}"
probe_email="${nonce}@test.flapjack.foo"
seed_password="SeedPass-${nonce}-Aa1!"
new_password="ResetPass-${nonce}-Aa1!"

register_payload="$(python3 - "$probe_email" "$seed_password" <<'PY'
import json
import sys
print(json.dumps({
    "name": "Stage2 Reset Probe",
    "email": sys.argv[1],
    "password": sys.argv[2],
}))
PY
)"
register_response="$(probe_post_json "$api_url" "/auth/register" "$register_payload" 2>&1)" || runtime_fail "register call failed: $register_response"
register_code="$(printf '%s\n' "$register_response" | sed -n '1p')"
register_body="$(printf '%s\n' "$register_response" | sed -n '2,$p')"
if [[ "$register_code" != "201" && "$register_code" != "200" ]]; then
    runtime_fail "register returned HTTP $register_code for $probe_email"
fi
customer_id="$(probe_json_field "$register_body" "customer_id")"
[[ -n "$customer_id" ]] || runtime_fail "register response missing customer_id"
probe_assert_customer_visible_or_wrong_db "$customer_id" "$probe_email" || exit $?

forgot_payload="$(python3 - "$probe_email" <<'PY'
import json
import sys
print(json.dumps({"email": sys.argv[1]}))
PY
)"
forgot_response="$(probe_post_json "$api_url" "/auth/forgot-password" "$forgot_payload" 2>&1)" || runtime_fail "forgot-password call failed: $forgot_response"
forgot_code="$(printf '%s\n' "$forgot_response" | sed -n '1p')"
if [[ "$forgot_code" != "200" ]]; then
    runtime_fail "forgot-password returned HTTP $forgot_code"
fi

rfc822_capture="$(probe_poll_rfc822_for_terms "$nonce" "/reset-password/" 2>&1)" || runtime_fail "failed polling inbound inbox for reset email: $rfc822_capture"
inbox_key="$(printf '%s\n' "$rfc822_capture" | sed -n '1p')"
rfc822_payload="$(printf '%s\n' "$rfc822_capture" | sed '1d')"
reset_token="$(test_inbox_extract_reset_token_from_rfc822 "$rfc822_payload")"
[[ -n "$reset_token" ]] || runtime_fail "password reset email for $probe_email did not contain a reset token"

reset_payload="$(python3 - "$reset_token" "$new_password" <<'PY'
import json
import sys
print(json.dumps({
    "token": sys.argv[1],
    "new_password": sys.argv[2],
}))
PY
)"
reset_response="$(probe_post_json "$api_url" "/auth/reset-password" "$reset_payload" 2>&1)" || runtime_fail "reset-password call failed: $reset_response"
reset_code="$(printf '%s\n' "$reset_response" | sed -n '1p')"
reset_body="$(printf '%s\n' "$reset_response" | sed -n '2,$p')"
if [[ "$reset_code" != "200" ]]; then
    runtime_fail "reset-password returned HTTP $reset_code"
fi
reset_message="$(probe_json_field "$reset_body" "message")"

login_payload="$(python3 - "$probe_email" "$new_password" <<'PY'
import json
import sys
print(json.dumps({
    "email": sys.argv[1],
    "password": sys.argv[2],
}))
PY
)"
login_response="$(probe_post_json "$api_url" "/auth/login" "$login_payload" 2>&1)" || runtime_fail "login call failed after password reset: $login_response"
login_code="$(printf '%s\n' "$login_response" | sed -n '1p')"
login_body="$(printf '%s\n' "$login_response" | sed -n '2,$p')"
if [[ "$login_code" != "200" ]]; then
    runtime_fail "login with new password returned HTTP $login_code"
fi
login_token="$(probe_json_field "$login_body" "token")"
login_customer_id="$(probe_json_field "$login_body" "customer_id")"
[[ -n "$login_token" && -n "$login_customer_id" ]] || runtime_fail "login response missing auth response fields after password reset"
[[ "$login_customer_id" == "$customer_id" ]] || runtime_fail "login customer_id ($login_customer_id) does not match registered customer_id ($customer_id)"

escaped_customer_id="$(probe_sql_escape_literal "$customer_id")"
token_cleared_sql="SELECT CASE WHEN password_reset_token IS NULL THEN 'cleared' ELSE 'present' END FROM customers WHERE id = '${escaped_customer_id}';"
reset_token_poll_max_attempts="${RESET_TOKEN_POLL_MAX_ATTEMPTS:-15}"
reset_token_poll_sleep_sec="${RESET_TOKEN_POLL_SLEEP_SEC:-2}"
test_inbox_require_nonnegative_int "$reset_token_poll_max_attempts" "RESET_TOKEN_POLL_MAX_ATTEMPTS" || precondition_fail "RESET_TOKEN_POLL_MAX_ATTEMPTS must be a positive integer"
test_inbox_require_nonnegative_int "$reset_token_poll_sleep_sec" "RESET_TOKEN_POLL_SLEEP_SEC" || precondition_fail "RESET_TOKEN_POLL_SLEEP_SEC must be a non-negative integer"
[[ "$reset_token_poll_max_attempts" -gt 0 ]] || precondition_fail "RESET_TOKEN_POLL_MAX_ATTEMPTS must be greater than zero"
if ! reset_attempts_used="$(reset_token_poll_until_cleared "$probe_email" "$token_cleared_sql" "$reset_token_poll_max_attempts" "$reset_token_poll_sleep_sec")"; then
    runtime_fail "password_reset_token not cleared after reset for $probe_email after ${reset_token_poll_max_attempts} attempts"
fi

echo "register_http=$register_code forgot_http=$forgot_code reset_http=$reset_code login_http=$login_code customer_id=$customer_id inbox_key=$inbox_key"
echo "reset_message=${reset_message:-password has been reset}"
echo "reset_db_attempts=$reset_attempts_used"
echo "TERMINUS: login succeeded with new password"
