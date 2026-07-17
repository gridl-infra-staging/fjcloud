#!/usr/bin/env bash
# Tests for scripts/probe_cloudflare_ai_block.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/probe_cloudflare_ai_block.sh"

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

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0

json_get_top_field() {
    local json="$1" field="$2"
    python3 - "$json" "$field" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
field = sys.argv[2]
value = payload.get(field, "")
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(str(value))
PY
}

json_get_step_field() {
    local json="$1" step_name="$2" field="$3"
    python3 - "$json" "$step_name" "$field" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
step_name = sys.argv[2]
field = sys.argv[3]
for step in payload.get("steps", []):
    if step.get("name") == step_name:
        value = step.get(field, "")
        if isinstance(value, bool):
            print("true" if value else "false")
        else:
            print(str(value))
        break
else:
    print("")
PY
}

make_curl_mock() {
    local bin_dir="$1"
    cat > "$bin_dir/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

: "${CLOUDFLARE_AI_BLOCK_CURL_CALL_LOG:?missing call log}"
: "${CLOUDFLARE_AI_BLOCK_CURL_STDIN_LOG:?missing stdin log}"
: "${CLOUDFLARE_AI_BLOCK_CURL_MODE:=success}"

printf '%s\n' "$*" >> "$CLOUDFLARE_AI_BLOCK_CURL_CALL_LOG"
cat > "$CLOUDFLARE_AI_BLOCK_CURL_STDIN_LOG"

if [[ "$CLOUDFLARE_AI_BLOCK_CURL_MODE" == "transport_error" ]]; then
    echo "simulated transport failure" >&2
    exit 7
fi

case "$CLOUDFLARE_AI_BLOCK_CURL_MODE" in
  success)
    cat <<'OUT'
{"success":true,"result":{"ai_bots_protection":"disabled"},"errors":[]}
HTTP_STATUS:200
OUT
    ;;
  http_403)
    cat <<'OUT'
{"success":false,"errors":[{"code":9109,"message":"Invalid access token"}]}
HTTP_STATUS:403
OUT
    ;;
  missing_ai)
    cat <<'OUT'
{"success":true,"result":{},"errors":[]}
HTTP_STATUS:200
OUT
    ;;
  malformed_json)
    cat <<'OUT'
not-json
HTTP_STATUS:200
OUT
    ;;
  *)
    echo "unknown mode: $CLOUDFLARE_AI_BLOCK_CURL_MODE" >&2
    exit 9
    ;;
esac
MOCK
    chmod +x "$bin_dir/curl"
}

run_probe() {
    local tmp_dir="$1"
    shift
    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"
    RUN_EXIT_CODE=0

    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        FJCLOUD_SECRET_FILE="$tmp_dir/does_not_exist.env" \
        "$@" \
        bash "$PROBE_SCRIPT" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

setup_mock_env() {
    local tmp_dir="$1"
    mkdir -p "$tmp_dir/bin"
    make_curl_mock "$tmp_dir/bin"
}

test_script_exists_and_sources_shared_helpers() {
    if [ -f "$PROBE_SCRIPT" ]; then
        pass "probe script exists"
    else
        fail "probe script should exist at $PROBE_SCRIPT"
        return
    fi

    local contents
    contents="$(cat "$PROBE_SCRIPT")"
    assert_contains "$contents" "lib/env.sh" "probe should reuse shared env loader"
    assert_contains "$contents" "lib/validation_json.sh" "probe should reuse validation JSON helper"
}

test_missing_global_key_fails_deterministically() {
    local tmp_dir call_log stdin_log
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/curl_calls.log"
    stdin_log="$tmp_dir/curl_stdin.log"
    : > "$call_log"
    : > "$stdin_log"

    run_probe "$tmp_dir" \
        "CLOUDFLARE_X_Auth_Email=operator@example.com" \
        "CLOUDFLARE_ZONE_ID_FLAPJACK_FOO=fafbf95a076d7e8ee984dbd18a62c933" \
        "CLOUDFLARE_AI_BLOCK_CURL_CALL_LOG=$call_log" \
        "CLOUDFLARE_AI_BLOCK_CURL_STDIN_LOG=$stdin_log"

    assert_eq "$RUN_EXIT_CODE" "2" "missing global key should fail with usage exit code"
    assert_valid_json "$RUN_STDOUT" "missing global key should still emit JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "false" "missing global key should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "readback" "detail")" "CLOUDFLARE_GLOBAL_API_KEY" "missing global key detail should name required var"
    assert_eq "$(wc -l < "$call_log" | tr -d "[:space:]")" "0" "missing global key should not call curl"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_missing_zone_fails_deterministically() {
    local tmp_dir call_log stdin_log
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/curl_calls.log"
    stdin_log="$tmp_dir/curl_stdin.log"
    : > "$call_log"
    : > "$stdin_log"

    run_probe "$tmp_dir" \
        "CLOUDFLARE_GLOBAL_API_KEY=key-value" \
        "CLOUDFLARE_X_Auth_Email=operator@example.com" \
        "CLOUDFLARE_AI_BLOCK_CURL_CALL_LOG=$call_log" \
        "CLOUDFLARE_AI_BLOCK_CURL_STDIN_LOG=$stdin_log"

    assert_eq "$RUN_EXIT_CODE" "2" "missing zone should fail with usage exit code"
    assert_valid_json "$RUN_STDOUT" "missing zone should emit JSON"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "readback" "detail")" "CLOUDFLARE_ZONE_ID_FLAPJACK_FOO" "missing zone detail should name zone env"
    assert_eq "$(wc -l < "$call_log" | tr -d "[:space:]")" "0" "missing zone should not call curl"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_http_failure_is_machine_readable_and_writes_raw_readback() {
    local tmp_dir call_log stdin_log run_dir raw_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    run_dir="$tmp_dir/evidence"
    mkdir -p "$run_dir"

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/curl_calls.log"
    stdin_log="$tmp_dir/curl_stdin.log"
    : > "$call_log"
    : > "$stdin_log"

    run_probe "$tmp_dir" \
        "CLOUDFLARE_GLOBAL_API_KEY=key-value" \
        "CLOUDFLARE_X_Auth_Email=operator@example.com" \
        "CLOUDFLARE_ZONE_ID_FLAPJACK_FOO=fafbf95a076d7e8ee984dbd18a62c933" \
        "CLOUDFLARE_AI_BLOCK_CURL_CALL_LOG=$call_log" \
        "CLOUDFLARE_AI_BLOCK_CURL_STDIN_LOG=$stdin_log" \
        "CLOUDFLARE_AI_BLOCK_CURL_MODE=http_403" \
        "CLOUDFLARE_AI_BLOCK_RUN_DIR=$run_dir"

    raw_file="$run_dir/cloudflare_ai_block_readback.txt"

    assert_eq "$RUN_EXIT_CODE" "1" "non-200 readback should fail with runtime exit code"
    assert_valid_json "$RUN_STDOUT" "non-200 readback should emit JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "false" "non-200 readback should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "readback" "detail")" "HTTP_STATUS:403" "failure detail should include HTTP status"
    if [ -f "$raw_file" ]; then
        pass "raw readback artifact should still be written on failure"
    else
        fail "raw readback artifact should exist on failure"
    fi
    assert_contains "$(cat "$raw_file" 2>/dev/null || true)" "HTTP_STATUS:403" "raw readback artifact should contain HTTP status marker"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_success_reads_ai_bots_protection_and_writes_artifact() {
    local tmp_dir call_log stdin_log run_dir raw_file calls stdin_payload
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    run_dir="$tmp_dir/evidence"
    mkdir -p "$run_dir"

    setup_mock_env "$tmp_dir"
    call_log="$tmp_dir/curl_calls.log"
    stdin_log="$tmp_dir/curl_stdin.log"
    : > "$call_log"
    : > "$stdin_log"

    run_probe "$tmp_dir" \
        "CLOUDFLARE_GLOBAL_API_KEY=key-value" \
        "CLOUDFLARE_X_Auth_Email=operator@example.com" \
        "CLOUDFLARE_ZONE_ID_FLAPJACK_FOO=fafbf95a076d7e8ee984dbd18a62c933" \
        "CLOUDFLARE_AI_BLOCK_CURL_CALL_LOG=$call_log" \
        "CLOUDFLARE_AI_BLOCK_CURL_STDIN_LOG=$stdin_log" \
        "CLOUDFLARE_AI_BLOCK_CURL_MODE=success" \
        "CLOUDFLARE_AI_BLOCK_RUN_DIR=$run_dir"

    raw_file="$run_dir/cloudflare_ai_block_readback.txt"
    calls="$(cat "$call_log")"
    stdin_payload="$(cat "$stdin_log")"

    assert_eq "$RUN_EXIT_CODE" "0" "success readback should exit 0"
    assert_valid_json "$RUN_STDOUT" "success readback should emit JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "true" "success readback should report passed=true"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "readback" "detail")" "ai_bots_protection='disabled'" "success detail should include extracted ai_bots_protection value"
    assert_contains "$calls" "-K -" "probe should pass curl config on stdin instead of argv headers"
    assert_contains "$stdin_payload" "url = \"https://api.cloudflare.com/client/v4/zones/fafbf95a076d7e8ee984dbd18a62c933/bot_management\"" "probe should target bot_management readback endpoint"
    assert_contains "$stdin_payload" "header = \"X-Auth-Key: key-value\"" "probe should send global key header via stdin config"
    assert_contains "$stdin_payload" "header = \"X-Auth-Email: operator@example.com\"" "probe should send auth email header via stdin config"
    if [ -f "$raw_file" ]; then
        pass "success run should write raw readback artifact"
    else
        fail "success run should write raw readback artifact"
    fi
    assert_contains "$(cat "$raw_file" 2>/dev/null || true)" "HTTP_STATUS:200" "raw readback artifact should contain success HTTP status marker"

    trap - RETURN
    rm -rf "$tmp_dir"
}

echo "=== probe_cloudflare_ai_block.sh tests ==="
test_script_exists_and_sources_shared_helpers
test_missing_global_key_fails_deterministically
test_missing_zone_fails_deterministically
test_http_failure_is_machine_readable_and_writes_raw_readback
test_success_reads_ai_bots_protection_and_writes_artifact

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
