#!/usr/bin/env bash
# Shared JSON HTTP request helpers for shell scripts.
# shellcheck disable=SC2034
#
# Callers provide:
# - API_URL for all calls
# - ADMIN_KEY for admin_call
#
# Response contract:
# - capture_json_response writes HTTP_RESPONSE_CODE, HTTP_RESPONSE_BODY, and
#   HTTP_RESPONSE_EXIT_STATUS globals.

api_json_call() {
    local method="$1"
    local path="$2"
    shift 2

    curl -sS -X "$method" "${API_URL}${path}" \
        -H "Content-Type: application/json" \
        "$@"
}

admin_call() {
    local method="$1"
    local path="$2"
    shift 2

    api_json_call "$method" "$path" \
        -H "x-admin-key: ${ADMIN_KEY}" \
        "$@"
}

tenant_call() {
    local method="$1"
    local path="$2"
    local token="$3"
    shift 3

    api_json_call "$method" "$path" \
        -H "Authorization: Bearer ${token}" \
        "$@"
}

capture_json_response() {
    local response
    local curl_status=0
    response=$("$@" -w "\n%{http_code}" 2>/dev/null) || curl_status=$?
    HTTP_RESPONSE_EXIT_STATUS=$curl_status
    HTTP_RESPONSE_CODE="$(printf '%s\n' "$response" | tail -1)"
    HTTP_RESPONSE_BODY="$(printf '%s\n' "$response" | sed '$d')"
}
