#!/usr/bin/env bash
# Validate local OAuth route shape without a live provider round-trip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/env.sh"

if [ -f "$REPO_ROOT/.env.local" ] && [ -z "${OAUTH_VALIDATE_SKIP_ENV_FILE:-}" ]; then
    # Match scripts/api-dev.sh local stack contract: explicit shell exports keep precedence.
    # The skip hook is used only by scripts/tests/validate_oauth_routes_test.sh so the
    # API_BASE_URL/API_URL precedence assertions stay deterministic regardless of whether
    # the operator has bootstrapped a real .env.local at the repo root.
    load_env_file "$REPO_ROOT/.env.local"
fi

trim_env_value() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

resolve_api_base_url() {
    printf '%s\n' "${API_BASE_URL:-${API_URL:-http://127.0.0.1:3001}}"
}

require_oauth_provider_config() {
    local required_vars=(
        "GOOGLE_OAUTH_CLIENT_ID"
        "GOOGLE_OAUTH_CLIENT_SECRET"
        "GITHUB_OAUTH_CLIENT_ID"
        "GITHUB_OAUTH_CLIENT_SECRET"
    )
    local missing=()
    local key raw trimmed

    for key in "${required_vars[@]}"; do
        raw="${!key:-}"
        trimmed="$(trim_env_value "$raw")"
        if [ -z "$trimmed" ]; then
            missing+=("$key")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "OAuth provider config missing: ${missing[*]}; cannot prove missing-cookie 400 exchange path while provider start/exchange routes are disabled." >&2
        echo "Set GOOGLE_OAUTH_CLIENT_* and GITHUB_OAUTH_CLIENT_* in .env.local (or export them) before running scripts/validate_oauth_routes.sh." >&2
        exit 1
    fi
}

read_location_header() {
    local headers_file="$1"
    # BSD awk on macOS ignores gawk's IGNORECASE pragma, so match the header name
    # case-insensitively by lowercasing the line before pattern matching. HTTP header
    # names are case-insensitive (RFC 9110) and Rust/axum emits lowercase "location:".
    awk '
        {
            line = $0
            lower = tolower(line)
            if (lower ~ /^location:/) {
                gsub(/\r$/, "", line)
                sub(/^[^:]+:[[:space:]]*/, "", line)
                print line
                exit
            }
        }
    ' "$headers_file"
}

probe_start_route() {
    local api_base_url="$1"
    local provider="$2"
    local url="$api_base_url/auth/oauth/$provider/start"
    local headers_file body_file http_code location
    headers_file="$(mktemp)"
    body_file="$(mktemp)"

    http_code="$(curl -sS -D "$headers_file" -o "$body_file" -w '%{http_code}' --url "$url")"

    if [ "$http_code" = "302" ]; then
        location="$(read_location_header "$headers_file")"
        if [ -z "$location" ]; then
            echo "OAuth start route '$provider' returned 302 but missing redirect Location header: $url" >&2
            rm -f "$headers_file" "$body_file"
            exit 1
        fi
    elif [ "$http_code" != "501" ]; then
        echo "OAuth start route '$provider' returned unexpected HTTP $http_code (expected 302 or 501): $url" >&2
        rm -f "$headers_file" "$body_file"
        exit 1
    fi

    rm -f "$headers_file" "$body_file"
}

probe_exchange_missing_cookie() {
    local api_base_url="$1"
    local provider="$2"
    local url="$api_base_url/auth/oauth/$provider/exchange"
    local headers_file body_file http_code payload
    headers_file="$(mktemp)"
    body_file="$(mktemp)"
    payload='{"code":"stage5-probe-code","csrf_token":"stage5-probe-csrf"}'

    http_code="$(
        curl -sS -D "$headers_file" -o "$body_file" -w '%{http_code}' \
            --url "$url" \
            -X POST \
            -H 'Content-Type: application/json' \
            --data "$payload"
    )"

    if [ "$http_code" != "400" ]; then
        echo "OAuth exchange route '$provider' returned HTTP $http_code without oauth_state cookie (expected 400): $url" >&2
        rm -f "$headers_file" "$body_file"
        exit 1
    fi

    if ! grep -q 'oauth_state_cookie_missing' "$body_file"; then
        echo "OAuth exchange route '$provider' did not return oauth_state_cookie_missing for missing-cookie flow: $url" >&2
        rm -f "$headers_file" "$body_file"
        exit 1
    fi

    rm -f "$headers_file" "$body_file"
}

main() {
    local api_base_url
    api_base_url="$(resolve_api_base_url)"

    require_oauth_provider_config
    probe_start_route "$api_base_url" "google"
    probe_start_route "$api_base_url" "github"
    probe_exchange_missing_cookie "$api_base_url" "google"
    probe_exchange_missing_cookie "$api_base_url" "github"

    echo "OAuth route validation passed for API base URL: $api_base_url"
}

main "$@"
