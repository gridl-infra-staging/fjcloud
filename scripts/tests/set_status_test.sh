#!/usr/bin/env bash
# Tests for scripts/set_status.sh runtime status publisher contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

SET_STATUS_SCRIPT="$REPO_ROOT/scripts/set_status.sh"

setup_mock_commands() {
    local tmp_dir="$1"
    local mock_bin="$tmp_dir/mock-bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${SET_STATUS_AWS_LOG:?}"

if [ -n "${EXPECT_SECRET_MARKER:-}" ] && [ "${SET_STATUS_SECRET_MARKER:-}" != "$EXPECT_SECRET_MARKER" ]; then
    echo "secret marker mismatch" >&2
    exit 42
fi

if [ "${1:-}" != "s3" ] || [ "${2:-}" != "cp" ]; then
    echo "unexpected aws command: $*" >&2
    exit 64
fi

source_path="${3:-}"
destination_path="${4:-}"
content_type=""
cache_control=""

shift 4
while [ "$#" -gt 0 ]; do
    case "$1" in
        --content-type)
            content_type="${2:-}"
            shift 2
            ;;
        --cache-control)
            cache_control="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

printf '%s\n' "$destination_path" > "${SET_STATUS_CAPTURED_DEST:?}"
printf '%s\n' "$content_type" > "${SET_STATUS_CAPTURED_CONTENT_TYPE:?}"
printf '%s\n' "$cache_control" > "${SET_STATUS_CAPTURED_CACHE_CONTROL:?}"
cp "$source_path" "${SET_STATUS_CAPTURED_UPLOAD_PAYLOAD:?}"
MOCK

    cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${SET_STATUS_CURL_LOG:?}"
url="${!#}"
printf '%s\n' "$url" > "${SET_STATUS_CAPTURED_URL:?}"

if [ "${SET_STATUS_CURL_FAIL:-0}" = "1" ]; then
    echo "curl failed" >&2
    exit 7
fi

response_file="${SET_STATUS_CURL_RESPONSE_FILE:-${SET_STATUS_CAPTURED_UPLOAD_PAYLOAD:-}}"
if [ -n "$response_file" ] && [ -f "$response_file" ]; then
    cat "$response_file"
else
    printf '%s\n' '{}'
fi
MOCK

    chmod +x "$mock_bin/aws" "$mock_bin/curl"
    printf '%s\n' "$mock_bin"
}

assert_no_side_effect_logs() {
    local aws_log="$1"
    local curl_log="$2"

    if [ -f "$aws_log" ] || [ -f "$curl_log" ]; then
        fail "invalid input should not trigger aws/curl side effects"
    else
        pass "invalid input should not trigger aws/curl side effects"
    fi
}

assert_payload_contract() {
    local payload_file="$1"

    if python3 - "$payload_file" <<'PY'
import json
import re
import sys

payload_path = sys.argv[1]
with open(payload_path, 'r', encoding='utf-8') as handle:
    payload = json.load(handle)

if set(payload.keys()) - {"status", "lastUpdated", "message"}:
    raise SystemExit(1)
if payload.get("status") not in {"operational", "degraded", "outage"}:
    raise SystemExit(1)
if not isinstance(payload.get("lastUpdated"), str):
    raise SystemExit(1)
if not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$", payload["lastUpdated"]):
    raise SystemExit(1)
if "message" in payload and not isinstance(payload["message"], str):
    raise SystemExit(1)
if "statusLabel" in payload or "hostname" in payload or "host" in payload:
    raise SystemExit(1)
PY
    then
        pass "payload must match runtime status contract fields"
    else
        fail "payload must match runtime status contract fields"
    fi
}

# ---------------------------------------------------------------------------
# Test: unsupported environment fails before aws/curl side effects
# ---------------------------------------------------------------------------
test_rejects_unsupported_environment() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local aws_log="$tmp_dir/aws.log"
    local curl_log="$tmp_dir/curl.log"
    local mock_bin
    mock_bin=$(setup_mock_commands "$tmp_dir")

    export SET_STATUS_AWS_LOG="$aws_log"
    export SET_STATUS_CURL_LOG="$curl_log"
    export SET_STATUS_CAPTURED_DEST="$tmp_dir/captured_dest.txt"
    export SET_STATUS_CAPTURED_CONTENT_TYPE="$tmp_dir/captured_content_type.txt"
    export SET_STATUS_CAPTURED_CACHE_CONTROL="$tmp_dir/captured_cache_control.txt"
    export SET_STATUS_CAPTURED_UPLOAD_PAYLOAD="$tmp_dir/upload_payload.json"
    export SET_STATUS_CAPTURED_URL="$tmp_dir/captured_url.txt"
    unset EXPECT_SECRET_MARKER

    local output exit_code=0
    output=$(PATH="$mock_bin:$PATH" bash "$SET_STATUS_SCRIPT" dev operational 2>&1) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "unsupported environment should fail"
    else
        fail "unsupported environment should fail"
    fi
    assert_contains "$output" "staging" "error output should describe supported environments"
    assert_contains "$output" "prod" "error output should describe supported environments"
    assert_no_side_effect_logs "$aws_log" "$curl_log"
}

# ---------------------------------------------------------------------------
# Test: unsupported status fails before aws/curl side effects
# ---------------------------------------------------------------------------
test_rejects_unsupported_status() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local aws_log="$tmp_dir/aws.log"
    local curl_log="$tmp_dir/curl.log"
    local mock_bin
    mock_bin=$(setup_mock_commands "$tmp_dir")

    export SET_STATUS_AWS_LOG="$aws_log"
    export SET_STATUS_CURL_LOG="$curl_log"
    export SET_STATUS_CAPTURED_DEST="$tmp_dir/captured_dest.txt"
    export SET_STATUS_CAPTURED_CONTENT_TYPE="$tmp_dir/captured_content_type.txt"
    export SET_STATUS_CAPTURED_CACHE_CONTROL="$tmp_dir/captured_cache_control.txt"
    export SET_STATUS_CAPTURED_UPLOAD_PAYLOAD="$tmp_dir/upload_payload.json"
    export SET_STATUS_CAPTURED_URL="$tmp_dir/captured_url.txt"
    unset EXPECT_SECRET_MARKER

    local output exit_code=0
    output=$(PATH="$mock_bin:$PATH" bash "$SET_STATUS_SCRIPT" staging unknown 2>&1) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "unsupported status should fail"
    else
        fail "unsupported status should fail"
    fi
    assert_contains "$output" "operational" "error output should describe supported statuses"
    assert_contains "$output" "degraded" "error output should describe supported statuses"
    assert_contains "$output" "outage" "error output should describe supported statuses"
    assert_no_side_effect_logs "$aws_log" "$curl_log"
}

# ---------------------------------------------------------------------------
# Test: FJCLOUD_SECRET_FILE override is loaded before aws publication
# ---------------------------------------------------------------------------
test_loads_secret_file_override_before_aws() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local mock_bin
    mock_bin=$(setup_mock_commands "$tmp_dir")

    cat > "$tmp_dir/override.env.secret" <<'EOF_SECRET'
SET_STATUS_SECRET_MARKER=override-secret-marker
EOF_SECRET

    export SET_STATUS_AWS_LOG="$tmp_dir/aws.log"
    export SET_STATUS_CURL_LOG="$tmp_dir/curl.log"
    export SET_STATUS_CAPTURED_DEST="$tmp_dir/captured_dest.txt"
    export SET_STATUS_CAPTURED_CONTENT_TYPE="$tmp_dir/captured_content_type.txt"
    export SET_STATUS_CAPTURED_CACHE_CONTROL="$tmp_dir/captured_cache_control.txt"
    export SET_STATUS_CAPTURED_UPLOAD_PAYLOAD="$tmp_dir/upload_payload.json"
    export SET_STATUS_CAPTURED_URL="$tmp_dir/captured_url.txt"
    export EXPECT_SECRET_MARKER="override-secret-marker"

    local exit_code=0
    PATH="$mock_bin:$PATH" FJCLOUD_SECRET_FILE="$tmp_dir/override.env.secret" \
        bash "$SET_STATUS_SCRIPT" staging operational "Override marker test" >/dev/null 2>&1 || exit_code=$?

    assert_eq "$exit_code" "0" "FJCLOUD_SECRET_FILE override should be loaded via load_env_file"
}

# ---------------------------------------------------------------------------
# Test: default repo secret path is used when override is unset
# ---------------------------------------------------------------------------
test_loads_default_secret_file_when_override_unset() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local repo_secret_dir="$REPO_ROOT/.secret"
    local repo_secret_file="$repo_secret_dir/.env.secret"
    local repo_secret_backup="$tmp_dir/repo.env.secret.backup"
    trap 'if [ -f "'"$repo_secret_backup"'" ]; then mkdir -p "'"$repo_secret_dir"'"; cp "'"$repo_secret_backup"'" "'"$repo_secret_file"'"; else rm -f "'"$repo_secret_file"'"; fi; rm -rf "'"$tmp_dir"'"' RETURN

    if [ -f "$repo_secret_file" ]; then
        cp "$repo_secret_file" "$repo_secret_backup"
    fi

    mkdir -p "$repo_secret_dir"
    cat > "$repo_secret_file" <<'EOF_SECRET'
SET_STATUS_SECRET_MARKER=default-secret-marker
EOF_SECRET

    local mock_bin
    mock_bin=$(setup_mock_commands "$tmp_dir")

    export SET_STATUS_AWS_LOG="$tmp_dir/aws.log"
    export SET_STATUS_CURL_LOG="$tmp_dir/curl.log"
    export SET_STATUS_CAPTURED_DEST="$tmp_dir/captured_dest.txt"
    export SET_STATUS_CAPTURED_CONTENT_TYPE="$tmp_dir/captured_content_type.txt"
    export SET_STATUS_CAPTURED_CACHE_CONTROL="$tmp_dir/captured_cache_control.txt"
    export SET_STATUS_CAPTURED_UPLOAD_PAYLOAD="$tmp_dir/upload_payload.json"
    export SET_STATUS_CAPTURED_URL="$tmp_dir/captured_url.txt"
    export EXPECT_SECRET_MARKER="default-secret-marker"

    local exit_code=0
    PATH="$mock_bin:$PATH" env -u FJCLOUD_SECRET_FILE \
        bash "$SET_STATUS_SCRIPT" prod degraded "Default marker test" >/dev/null 2>&1 || exit_code=$?

    assert_eq "$exit_code" "0" "default repo secret file should load when override is unset"
}

# ---------------------------------------------------------------------------
# Test: publication transport and payload contract for valid invocation
# ---------------------------------------------------------------------------
test_publishes_expected_object_and_payload_contract() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local mock_bin
    mock_bin=$(setup_mock_commands "$tmp_dir")

    export SET_STATUS_AWS_LOG="$tmp_dir/aws.log"
    export SET_STATUS_CURL_LOG="$tmp_dir/curl.log"
    export SET_STATUS_CAPTURED_DEST="$tmp_dir/captured_dest.txt"
    export SET_STATUS_CAPTURED_CONTENT_TYPE="$tmp_dir/captured_content_type.txt"
    export SET_STATUS_CAPTURED_CACHE_CONTROL="$tmp_dir/captured_cache_control.txt"
    export SET_STATUS_CAPTURED_UPLOAD_PAYLOAD="$tmp_dir/upload_payload.json"
    export SET_STATUS_CAPTURED_URL="$tmp_dir/captured_url.txt"
    unset EXPECT_SECRET_MARKER

    local output exit_code=0
    output=$(PATH="$mock_bin:$PATH" bash "$SET_STATUS_SCRIPT" staging outage "Investigating elevated API errors" 2>&1) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "valid invocation should succeed (exit=$exit_code output='$output')"
        return
    fi
    pass "valid invocation should succeed"
    assert_contains "$output" "service_status.json" "script output should mention published object"

    local destination content_type cache_control fetched_url
    destination=$(cat "$SET_STATUS_CAPTURED_DEST")
    content_type=$(cat "$SET_STATUS_CAPTURED_CONTENT_TYPE")
    cache_control=$(cat "$SET_STATUS_CAPTURED_CACHE_CONTROL")
    fetched_url=$(cat "$SET_STATUS_CAPTURED_URL")

    assert_eq "$destination" "s3://fjcloud-releases-staging/service_status.json" \
        "upload destination should target the runtime object"
    assert_eq "$content_type" "application/json" \
        "upload should set JSON content type"
    assert_eq "$cache_control" "no-store" \
        "upload should disable caching"
    assert_eq "$fetched_url" "https://fjcloud-releases-staging.s3.amazonaws.com/service_status.json" \
        "verification must fetch the exact public service_status.json object"

    assert_valid_json "$(cat "$SET_STATUS_CAPTURED_UPLOAD_PAYLOAD")" "uploaded payload should be valid JSON"
    assert_payload_contract "$SET_STATUS_CAPTURED_UPLOAD_PAYLOAD"

    local payload_text
    payload_text=$(cat "$SET_STATUS_CAPTURED_UPLOAD_PAYLOAD")
    assert_not_contains "$payload_text" "statusLabel" "payload must not include statusLabel"
    assert_not_contains "$payload_text" "All Systems Operational" "payload must not include shell-derived label text"
    assert_not_contains "$payload_text" "hostname" "payload must not include hostname metadata"
}

# ---------------------------------------------------------------------------
# Test: optional message is omitted when absent
# ---------------------------------------------------------------------------
test_omits_message_when_not_provided() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local mock_bin
    mock_bin=$(setup_mock_commands "$tmp_dir")

    export SET_STATUS_AWS_LOG="$tmp_dir/aws.log"
    export SET_STATUS_CURL_LOG="$tmp_dir/curl.log"
    export SET_STATUS_CAPTURED_DEST="$tmp_dir/captured_dest.txt"
    export SET_STATUS_CAPTURED_CONTENT_TYPE="$tmp_dir/captured_content_type.txt"
    export SET_STATUS_CAPTURED_CACHE_CONTROL="$tmp_dir/captured_cache_control.txt"
    export SET_STATUS_CAPTURED_UPLOAD_PAYLOAD="$tmp_dir/upload_payload.json"
    export SET_STATUS_CAPTURED_URL="$tmp_dir/captured_url.txt"
    unset EXPECT_SECRET_MARKER

    local exit_code=0
    PATH="$mock_bin:$PATH" bash "$SET_STATUS_SCRIPT" prod operational >/dev/null 2>&1 || exit_code=$?
    assert_eq "$exit_code" "0" "invocation without message should succeed"

    if [ ! -f "$SET_STATUS_CAPTURED_UPLOAD_PAYLOAD" ]; then
        fail "payload should be captured after invocation without message"
        return
    fi

    if python3 - "$SET_STATUS_CAPTURED_UPLOAD_PAYLOAD" <<'PY'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    payload = json.load(handle)
if 'message' in payload:
    raise SystemExit(1)
PY
    then
        pass "payload should omit message field when no message arg is provided"
    else
        fail "payload should omit message field when no message arg is provided"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_rejects_unsupported_environment
test_rejects_unsupported_status
test_loads_secret_file_override_before_aws
test_loads_default_secret_file_when_override_unset
test_publishes_expected_object_and_payload_contract
test_omits_message_when_not_provided

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
