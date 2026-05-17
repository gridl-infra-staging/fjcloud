#!/usr/bin/env bash
# Privacy.com transport owner for create/get/list/close card flows.
# shellcheck disable=SC1091,SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
# shellcheck source=http_json.sh
source "$SCRIPT_DIR/http_json.sh"

PRIVACY_CLIENT_EXIT_OK=0
PRIVACY_CLIENT_EXIT_CURL_FAILURE=11
PRIVACY_CLIENT_EXIT_HTTP_ERROR=12
PRIVACY_CLIENT_EXIT_INVALID_JSON=13
PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH=14

PRIVACY_CLIENT_EXIT_CLASS=""
PRIVACY_CLIENT_HTTP_CODE=""
PRIVACY_CLIENT_BODY=""
PRIVACY_CLIENT_ERROR_MESSAGE=""

# Shared lane-owned memo prefixes used by reclaim/sweeper workflows.
PRIVACY_LANE_MEMO_PREFIXES=(
    "fjcloud stage2 contract probe"
    "stage1-live-contract-probe"
)

privacy_com_set_result() {
    PRIVACY_CLIENT_EXIT_CLASS="$1"
    PRIVACY_CLIENT_HTTP_CODE="$2"
    PRIVACY_CLIENT_BODY="$3"
    PRIVACY_CLIENT_ERROR_MESSAGE="$4"
}

privacy_com_require_env() {
    local default_secret_file=".secret/.env.secret"
    local secret_file="${FJCLOUD_SECRET_FILE:-$default_secret_file}"
    load_layered_env_files "$secret_file"

    PRIVACY_BASE_URL="${PRIVACY_BASE_URL:-https://api.privacy.com}"
    PRIVACY_API_KEY="${PRIVACY_API_KEY:-${PRIVACY_COM_API_KEY:-${PRIVACY_PRODUCTION_API_KEY:-}}}"

    if [ -z "$PRIVACY_API_KEY" ]; then
        privacy_com_set_result "env_error" "" "" "PRIVACY_API_KEY is required"
        return 10
    fi
}

privacy_com_validate_json_body() {
    local body="$1"
    python3 - "$body" <<"PY" >/dev/null
import json
import sys
json.loads(sys.argv[1])
PY
}

privacy_com_validate_schema() {
    local body="$1"
    local schema_kind="$2"
    python3 - "$body" "$schema_kind" <<"PY"
import json
import sys

body = sys.argv[1]
schema_kind = sys.argv[2]

try:
    parsed = json.loads(body)
except Exception:
    raise SystemExit(2)

def require_keys(obj, keys, label):
    if not isinstance(obj, dict):
        raise SystemExit(f"{label} not object")
    for key in keys:
        if key not in obj:
            raise SystemExit(f"{label} missing key: {key}")
        value = obj[key]
        if value is None or value == "":
            raise SystemExit(f"{label} empty key: {key}")

if schema_kind == "list":
    require_keys(parsed, ["data", "page", "total_entries", "total_pages"], "list")
    if not isinstance(parsed["data"], list):
        raise SystemExit("list.data not array")
    if parsed["data"]:
        card = parsed["data"][0]
        require_keys(card, ["token", "state", "type", "spend_limit", "spend_limit_duration", "created", "funding", "exp_month", "exp_year"], "card")
        require_keys(card["funding"], ["token", "state", "type", "created"], "funding")
elif schema_kind == "card":
    require_keys(parsed, ["token", "state", "type", "spend_limit", "spend_limit_duration", "created", "funding", "exp_month", "exp_year"], "card")
    require_keys(parsed["funding"], ["token", "state", "type", "created"], "funding")
else:
    raise SystemExit(f"unknown schema kind: {schema_kind}")
PY
}

privacy_com_request() {
    local method="$1"
    local path="$2"
    local auth_mode="$3"
    local body="${4:-}"

    local -a headers
    headers=(-H "Content-Type: application/json")
    case "$auth_mode" in
        raw)
            headers+=( -H "Authorization: ${PRIVACY_API_KEY}" )
            ;;
        prefixed)
            headers+=( -H "Authorization: api-key ${PRIVACY_API_KEY}" )
            ;;
        missing)
            ;;
        *)
            privacy_com_set_result "schema_mismatch" "" "" "unknown auth mode: $auth_mode"
            return "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH"
            ;;
    esac

    local -a curl_args
    curl_args=(curl -sS --connect-timeout 10 --max-time 30 -X "$method" "${PRIVACY_BASE_URL}${path}" "${headers[@]}")
    if [ -n "$body" ]; then
        curl_args+=(--data "$body")
    fi

    capture_json_response "${curl_args[@]}"

    if [ "${HTTP_RESPONSE_EXIT_STATUS:-0}" -ne 0 ]; then
        privacy_com_set_result "curl_failure" "${HTTP_RESPONSE_CODE:-000}" "${HTTP_RESPONSE_BODY:-}" "curl transport failure"
        return "$PRIVACY_CLIENT_EXIT_CURL_FAILURE"
    fi

    PRIVACY_CLIENT_HTTP_CODE="$HTTP_RESPONSE_CODE"
    PRIVACY_CLIENT_BODY="$HTTP_RESPONSE_BODY"

    if ! [[ "$HTTP_RESPONSE_CODE" =~ ^[0-9]{3}$ ]]; then
        privacy_com_set_result "curl_failure" "$HTTP_RESPONSE_CODE" "$HTTP_RESPONSE_BODY" "curl failed before HTTP response"
        return "$PRIVACY_CLIENT_EXIT_CURL_FAILURE"
    fi

    if [[ "$HTTP_RESPONSE_CODE" != 2* ]]; then
        privacy_com_set_result "http_error" "$HTTP_RESPONSE_CODE" "$HTTP_RESPONSE_BODY" "HTTP non-2xx response"
        return "$PRIVACY_CLIENT_EXIT_HTTP_ERROR"
    fi

    if ! privacy_com_validate_json_body "$HTTP_RESPONSE_BODY"; then
        privacy_com_set_result "invalid_json" "$HTTP_RESPONSE_CODE" "$HTTP_RESPONSE_BODY" "response body is not valid json"
        return "$PRIVACY_CLIENT_EXIT_INVALID_JSON"
    fi

    privacy_com_set_result "ok" "$HTTP_RESPONSE_CODE" "$HTTP_RESPONSE_BODY" ""
    return "$PRIVACY_CLIENT_EXIT_OK"
}

privacy_com_list_cards_raw_auth() {
    local page="${1:-1}"
    local page_size="${2:-2}"
    privacy_com_request "GET" "/v1/cards?page=${page}&page_size=${page_size}" "raw"
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    if ! privacy_com_validate_schema "$PRIVACY_CLIENT_BODY" "list" >/dev/null 2>&1; then
        privacy_com_set_result "schema_mismatch" "$PRIVACY_CLIENT_HTTP_CODE" "$PRIVACY_CLIENT_BODY" "list response schema mismatch"
        return "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH"
    fi
}

privacy_com_list_cards_prefixed_auth() {
    local page="${1:-1}"
    local page_size="${2:-2}"
    privacy_com_request "GET" "/v1/cards?page=${page}&page_size=${page_size}" "prefixed"
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    if ! privacy_com_validate_schema "$PRIVACY_CLIENT_BODY" "list" >/dev/null 2>&1; then
        privacy_com_set_result "schema_mismatch" "$PRIVACY_CLIENT_HTTP_CODE" "$PRIVACY_CLIENT_BODY" "list response schema mismatch"
        return "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH"
    fi
}

privacy_com_list_cards_missing_auth() {
    local page="${1:-1}"
    local page_size="${2:-2}"
    privacy_com_request "GET" "/v1/cards?page=${page}&page_size=${page_size}" "missing"
}

extract_total_pages() {
    local json_body="$1"
    python3 - "$json_body" <<'PY'
import json
import sys

body = json.loads(sys.argv[1])
total_pages = body.get("total_pages", 1)
try:
    total_pages = int(total_pages)
except Exception:
    total_pages = 1
if total_pages < 1:
    total_pages = 1
print(total_pages)
PY
}

privacy_com_create_card() {
    local request_body
    request_body="$(cat <<JSON
{"type":"MERCHANT_LOCKED","memo":"fjcloud stage2 contract probe","spend_limit":1000,"spend_limit_duration":"TRANSACTION","state":"OPEN"}
JSON
)"
    privacy_com_request "POST" "/v1/cards" "raw" "$request_body"
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    if ! privacy_com_validate_schema "$PRIVACY_CLIENT_BODY" "card" >/dev/null 2>&1; then
        privacy_com_set_result "schema_mismatch" "$PRIVACY_CLIENT_HTTP_CODE" "$PRIVACY_CLIENT_BODY" "create response schema mismatch"
        return "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH"
    fi
}

privacy_com_get_card() {
    local card_token="$1"
    if [ -z "$card_token" ]; then
        privacy_com_set_result "schema_mismatch" "" "" "card token is required"
        return "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH"
    fi

    privacy_com_request "GET" "/v1/cards/${card_token}" "raw"
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    if ! privacy_com_validate_schema "$PRIVACY_CLIENT_BODY" "card" >/dev/null 2>&1; then
        privacy_com_set_result "schema_mismatch" "$PRIVACY_CLIENT_HTTP_CODE" "$PRIVACY_CLIENT_BODY" "get response schema mismatch"
        return "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH"
    fi
}

privacy_com_close_card() {
    local card_token="$1"
    if [ -z "$card_token" ]; then
        privacy_com_set_result "schema_mismatch" "" "" "card token is required"
        return "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH"
    fi

    privacy_com_request "PATCH" "/v1/cards/${card_token}" "raw" '{"state":"CLOSED"}'
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    if ! privacy_com_validate_schema "$PRIVACY_CLIENT_BODY" "card" >/dev/null 2>&1; then
        privacy_com_set_result "schema_mismatch" "$PRIVACY_CLIENT_HTTP_CODE" "$PRIVACY_CLIENT_BODY" "close response schema mismatch"
        return "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH"
    fi
}
