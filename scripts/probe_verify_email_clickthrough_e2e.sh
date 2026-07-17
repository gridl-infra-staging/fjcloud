#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/clickthrough_probe_common.sh"

EXIT_USAGE=2
EXIT_PRECONDITION=3
EXIT_RUNTIME=1

usage() {
    cat <<'USAGE'
Usage: bash scripts/probe_verify_email_clickthrough_e2e.sh <env-file>
   or: bash scripts/probe_verify_email_clickthrough_e2e.sh --env-file <path>
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

verify_email_poll_until_verified() {
    local probe_email="$1"
    local verified_sql="$2"
    local max_attempts="$3"
    local sleep_seconds="$4"
    local attempt=1
    local verified_marker=""

    while [[ "$attempt" -le "$max_attempts" ]]; do
        verified_marker="$(probe_trim "$(probe_sql_single_value "$verified_sql" 2>&1)")" || runtime_fail "failed reading email_verified_at for $probe_email"
        if [[ "$verified_marker" == "true" ]]; then
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
probe_materialize_app_base_url_from_staging_tool_env
export DATABASE_URL="${DATABASE_URL:-${INTEGRATION_DB_URL:-}}"

api_url="$(probe_required_env_value API_URL 2>/dev/null || true)"
app_base_url="$(probe_required_env_value APP_BASE_URL 2>/dev/null || true)"
ses_from_address="$(probe_required_env_value SES_FROM_ADDRESS 2>/dev/null || true)"
ses_region="$(probe_required_env_value SES_REGION 2>/dev/null || true)"

[[ -n "$api_url" ]] || precondition_fail "API_URL is required"
[[ -n "$app_base_url" ]] || precondition_fail "APP_BASE_URL is required"
[[ -n "$ses_from_address" ]] || precondition_fail "SES_FROM_ADDRESS is required"
[[ -n "$ses_region" ]] || precondition_fail "SES_REGION is required"

nonce="verifyprobe$(date -u +%Y%m%d%H%M%S)${RANDOM}"
probe_email="${nonce}@test.flapjack.foo"
password="ProbePass-${nonce}-Aa1!"

register_payload="$(python3 - "$probe_email" "$password" <<'PY'
import json
import sys
print(json.dumps({
    "name": "Stage2 Verify Probe",
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

rfc822_capture="$(probe_poll_rfc822_for_terms "$nonce" "/verify-email/" 2>&1)" || runtime_fail "failed polling inbound inbox for verification email: $rfc822_capture"
inbox_key="$(printf '%s\n' "$rfc822_capture" | sed -n '1p')"
rfc822_payload="$(printf '%s\n' "$rfc822_capture" | sed '1d')"
verify_token="$(test_inbox_extract_verify_token_from_rfc822 "$rfc822_payload")"
[[ -n "$verify_token" ]] || runtime_fail "verification email for $probe_email did not contain a verify token"

verify_raw="$(curl -sSL -w $'\n%{http_code}' "${app_base_url%/}/verify-email/${verify_token}" 2>&1)" || runtime_fail "verify-email page request failed"
verify_code="$(printf '%s\n' "$verify_raw" | tail -n 1)"
verify_body="$(printf '%s\n' "$verify_raw" | sed '$d')"
if [[ "$verify_code" != "200" ]]; then
    runtime_fail "verify-email page returned HTTP $verify_code"
fi
if ! printf '%s\n' "$verify_body" | grep -q 'data-success="true"'; then
    runtime_fail "verify-email page rendered failure branch — token invalid or expired"
fi

escaped_email="$(probe_sql_escape_literal "$probe_email")"
verified_sql="SELECT CASE WHEN email_verified_at IS NULL THEN 'false' ELSE 'true' END FROM customers WHERE email = '${escaped_email}' ORDER BY created_at DESC LIMIT 1;"
verify_email_poll_max_attempts="${VERIFY_EMAIL_DB_POLL_MAX_ATTEMPTS:-15}"
verify_email_poll_sleep_sec="${VERIFY_EMAIL_DB_POLL_SLEEP_SEC:-2}"
test_inbox_require_nonnegative_int "$verify_email_poll_max_attempts" "VERIFY_EMAIL_DB_POLL_MAX_ATTEMPTS" || precondition_fail "VERIFY_EMAIL_DB_POLL_MAX_ATTEMPTS must be a positive integer"
test_inbox_require_nonnegative_int "$verify_email_poll_sleep_sec" "VERIFY_EMAIL_DB_POLL_SLEEP_SEC" || precondition_fail "VERIFY_EMAIL_DB_POLL_SLEEP_SEC must be a non-negative integer"
[[ "$verify_email_poll_max_attempts" -gt 0 ]] || precondition_fail "VERIFY_EMAIL_DB_POLL_MAX_ATTEMPTS must be greater than zero"
if ! verify_attempts_used="$(verify_email_poll_until_verified "$probe_email" "$verified_sql" "$verify_email_poll_max_attempts" "$verify_email_poll_sleep_sec")"; then
    runtime_fail "email_verified_at not set after clickthrough for $probe_email after ${verify_email_poll_max_attempts} attempts"
fi

echo "probe_email=$probe_email register_http=$register_code verify_page_http=$verify_code customer_id=$customer_id inbox_key=$inbox_key verify_db_attempts=$verify_attempts_used"
echo "TERMINUS: email_verified=true"
