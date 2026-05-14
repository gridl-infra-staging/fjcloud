#!/usr/bin/env bash
# Tests for scripts/validate_oauth_routes.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"
source "$REPO_ROOT/scripts/tests/lib/test_helpers.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

write_mock_curl() {
    local mock_path="$1"
    cat > "$mock_path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

header_file=""
body_file=""
write_format=""
url=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -D)
            header_file="$2"
            shift 2
            ;;
        -o)
            body_file="$2"
            shift 2
            ;;
        -w)
            write_format="$2"
            shift 2
            ;;
        --url)
            url="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [ -n "${OAUTH_ROUTE_MOCK_URL_LOG:-}" ] && [ -n "$url" ]; then
    printf '%s\n' "$url" >> "$OAUTH_ROUTE_MOCK_URL_LOG"
fi

if [ -z "${OAUTH_ROUTE_MOCK_RESPONSES:-}" ]; then
    echo "missing OAUTH_ROUTE_MOCK_RESPONSES" >&2
    exit 1
fi

python3 - "$OAUTH_ROUTE_MOCK_RESPONSES" "$header_file" "$body_file" "$write_format" <<'PY'
import json
import sys
from pathlib import Path

responses_path, header_file, body_file, write_format = sys.argv[1:5]
state = json.loads(Path(responses_path).read_text())
idx = int(state.get("index", 0))
responses = state.get("responses", [])
if idx >= len(responses):
    raise SystemExit("mock response sequence exhausted")

response = responses[idx]
state["index"] = idx + 1
Path(responses_path).write_text(json.dumps(state))

status = str(response.get("status", 500))
headers = response.get("headers", {})
body = response.get("body", "")

if header_file:
    header_lines = ["HTTP/1.1 " + status + " Mock"]
    for key, value in headers.items():
        header_lines.append(f"{key}: {value}")
    Path(header_file).write_text("\r\n".join(header_lines) + "\r\n\r\n")

if body_file:
    Path(body_file).write_text(body)

if write_format:
    sys.stdout.write(write_format.replace("%{http_code}", status))
else:
    sys.stdout.write(status)
PY
MOCK
    chmod +x "$mock_path"
}

write_mock_responses() {
    local path="$1"
    local payload="$2"
    cat > "$path" <<EOF_JSON
$payload
EOF_JSON
}

test_validate_oauth_routes_prefers_api_base_url_over_api_url() {
    local mock_dir response_file url_log output exit_code
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    url_log="$mock_dir/urls.log"
    write_mock_responses "$response_file" '{"index":0,"responses":[
      {"status":302,"headers":{"Location":"https://accounts.google.com/o/oauth2/v2/auth?state=abc"}},
      {"status":302,"headers":{"Location":"https://github.com/login/oauth/authorize?state=abc"}},
      {"status":400,"body":"{\"error\":\"oauth_state_cookie_missing\"}"},
      {"status":400,"body":"{\"error\":\"oauth_state_cookie_missing\"}"}
    ]}'
    write_mock_curl "$mock_dir/curl"

    output="$(
        API_BASE_URL='http://api-base.test:4001' \
        API_URL='http://api-url.test:4999' \
        GOOGLE_OAUTH_CLIENT_ID='google-id' \
        GOOGLE_OAUTH_CLIENT_SECRET='google-secret' \
        GITHUB_OAUTH_CLIENT_ID='github-id' \
        GITHUB_OAUTH_CLIENT_SECRET='github-secret' \
        OAUTH_ROUTE_MOCK_RESPONSES="$response_file" \
        OAUTH_ROUTE_MOCK_URL_LOG="$url_log" \
        OAUTH_VALIDATE_SKIP_ENV_FILE=1 \
        PATH="$mock_dir:$PATH" \
        bash "$REPO_ROOT/scripts/validate_oauth_routes.sh" 2>&1
    )" || exit_code=$?

    local urls
    urls="$(cat "$url_log" 2>/dev/null || true)"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validate_oauth_routes should pass with 302 start routes and 400 exchange responses"
    assert_contains "$output" "OAuth route validation passed" "validate_oauth_routes should emit success summary"
    assert_contains "$urls" "http://api-base.test:4001/auth/oauth/google/start" "API_BASE_URL should drive google start probe"
    assert_contains "$urls" "http://api-base.test:4001/auth/oauth/github/start" "API_BASE_URL should drive github start probe"
    assert_not_contains "$urls" "http://api-url.test:4999/auth/oauth/google/start" "API_URL should not override API_BASE_URL"
}

test_validate_oauth_routes_falls_back_to_api_url_when_api_base_url_unset() {
    local mock_dir response_file url_log output exit_code
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    url_log="$mock_dir/urls.log"
    write_mock_responses "$response_file" '{"index":0,"responses":[
      {"status":501},
      {"status":501},
      {"status":400,"body":"{\"error\":\"oauth_state_cookie_missing\"}"},
      {"status":400,"body":"{\"error\":\"oauth_state_cookie_missing\"}"}
    ]}'
    write_mock_curl "$mock_dir/curl"

    output="$(
        env -u API_BASE_URL \
        API_URL='http://fallback-api.test:4111' \
        GOOGLE_OAUTH_CLIENT_ID='google-id' \
        GOOGLE_OAUTH_CLIENT_SECRET='google-secret' \
        GITHUB_OAUTH_CLIENT_ID='github-id' \
        GITHUB_OAUTH_CLIENT_SECRET='github-secret' \
        OAUTH_ROUTE_MOCK_RESPONSES="$response_file" \
        OAUTH_ROUTE_MOCK_URL_LOG="$url_log" \
        OAUTH_VALIDATE_SKIP_ENV_FILE=1 \
        PATH="$mock_dir:$PATH" \
        bash "$REPO_ROOT/scripts/validate_oauth_routes.sh" 2>&1
    )" || exit_code=$?

    local urls
    urls="$(cat "$url_log" 2>/dev/null || true)"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validate_oauth_routes should accept 501 for start routes while preserving exchange 400 checks"
    assert_contains "$urls" "http://fallback-api.test:4111/auth/oauth/google/start" "API_URL should drive probe when API_BASE_URL is unset"
}

test_validate_oauth_routes_rejects_302_without_location_header() {
    local mock_dir response_file output exit_code
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    write_mock_responses "$response_file" '{"index":0,"responses":[
      {"status":302,"headers":{}},
      {"status":501},
      {"status":400,"body":"{\"error\":\"oauth_state_cookie_missing\"}"},
      {"status":400,"body":"{\"error\":\"oauth_state_cookie_missing\"}"}
    ]}'
    write_mock_curl "$mock_dir/curl"

    output="$(
        API_BASE_URL='http://api-base.test:4001' \
        GOOGLE_OAUTH_CLIENT_ID='google-id' \
        GOOGLE_OAUTH_CLIENT_SECRET='google-secret' \
        GITHUB_OAUTH_CLIENT_ID='github-id' \
        GITHUB_OAUTH_CLIENT_SECRET='github-secret' \
        OAUTH_ROUTE_MOCK_RESPONSES="$response_file" \
        OAUTH_VALIDATE_SKIP_ENV_FILE=1 \
        PATH="$mock_dir:$PATH" \
        bash "$REPO_ROOT/scripts/validate_oauth_routes.sh" 2>&1
    )" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate_oauth_routes should fail when 302 omits Location header"
    assert_contains "$output" "missing redirect Location header" "validate_oauth_routes should explain missing Location header"
}

test_validate_oauth_routes_fails_when_oauth_provider_config_missing() {
    local mock_dir response_file output exit_code
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    write_mock_responses "$response_file" '{"index":0,"responses":[]}'
    write_mock_curl "$mock_dir/curl"

    output="$(
        API_BASE_URL='http://api-base.test:4001' \
        GOOGLE_OAUTH_CLIENT_ID='' \
        GOOGLE_OAUTH_CLIENT_SECRET='' \
        GITHUB_OAUTH_CLIENT_ID='' \
        GITHUB_OAUTH_CLIENT_SECRET='' \
        OAUTH_ROUTE_MOCK_RESPONSES="$response_file" \
        OAUTH_VALIDATE_SKIP_ENV_FILE=1 \
        PATH="$mock_dir:$PATH" \
        bash "$REPO_ROOT/scripts/validate_oauth_routes.sh" 2>&1
    )" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate_oauth_routes should fail when OAuth provider config is missing"
    assert_contains "$output" "OAuth provider config missing" "validate_oauth_routes should emit prerequisite failure message"
    assert_contains "$output" "cannot prove missing-cookie 400 exchange path" "validate_oauth_routes should explain why missing config blocks the exchange proof"
}

test_validate_oauth_routes_accepts_lowercase_location_header() {
    # Regression for the gawk IGNORECASE assumption: macOS BSD awk does not honor
    # IGNORECASE, so the prior probe failed when axum emitted lowercase "location:".
    local mock_dir response_file output exit_code
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    write_mock_responses "$response_file" '{"index":0,"responses":[
      {"status":302,"headers":{"location":"https://accounts.google.com/o/oauth2/v2/auth?state=lc"}},
      {"status":302,"headers":{"location":"https://github.com/login/oauth/authorize?state=lc"}},
      {"status":400,"body":"{\"error\":\"oauth_state_cookie_missing\"}"},
      {"status":400,"body":"{\"error\":\"oauth_state_cookie_missing\"}"}
    ]}'
    write_mock_curl "$mock_dir/curl"

    output="$(
        API_BASE_URL='http://api-base.test:4001' \
        GOOGLE_OAUTH_CLIENT_ID='google-id' \
        GOOGLE_OAUTH_CLIENT_SECRET='google-secret' \
        GITHUB_OAUTH_CLIENT_ID='github-id' \
        GITHUB_OAUTH_CLIENT_SECRET='github-secret' \
        OAUTH_ROUTE_MOCK_RESPONSES="$response_file" \
        OAUTH_VALIDATE_SKIP_ENV_FILE=1 \
        PATH="$mock_dir:$PATH" \
        bash "$REPO_ROOT/scripts/validate_oauth_routes.sh" 2>&1
    )" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validate_oauth_routes should accept lowercase 'location:' header from axum"
    assert_contains "$output" "OAuth route validation passed" "lowercase location header should not block 302 acceptance"
}

echo "=== validate_oauth_routes.sh tests ==="
test_validate_oauth_routes_prefers_api_base_url_over_api_url
test_validate_oauth_routes_falls_back_to_api_url_when_api_base_url_unset
test_validate_oauth_routes_rejects_302_without_location_header
test_validate_oauth_routes_fails_when_oauth_provider_config_missing
test_validate_oauth_routes_accepts_lowercase_location_header

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
