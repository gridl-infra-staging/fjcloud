#!/usr/bin/env bash
# Contract test for scripts/canary/outside_aws_health_check.sh.
#
# Red-stage expectation before implementation:
# - scripts/canary/outside_aws_health_check.sh does not exist yet.
# - This test must fail for that missing owner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/canary/outside_aws_health_check.sh"

PASS_COUNT=0
FAIL_COUNT=0

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0

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

write_curl_mock() {
    local mock_path="$1"
    cat > "$mock_path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

: "${CURL_CALL_LOG:?CURL_CALL_LOG is required}"
: "${CURL_ARGS_LOG:?CURL_ARGS_LOG is required}"

url=""
for arg in "$@"; do
    if [[ "$arg" == http://* || "$arg" == https://* ]]; then
        url="$arg"
    fi
done

printf '%s\n' "$url" >> "$CURL_CALL_LOG"
printf '%s\n' "$*" >> "$CURL_ARGS_LOG"

http_code="${MOCK_CURL_HTTP_CODE:-200}"
exit_code="${MOCK_CURL_EXIT_CODE:-0}"
if [[ "$url" == "https://cloud.flapjack.foo/health" ]]; then
    http_code="${MOCK_CURL_HTTP_CODE_CLOUD:-$http_code}"
    exit_code="${MOCK_CURL_EXIT_CODE_CLOUD:-$exit_code}"
elif [[ "$url" == "https://api.flapjack.foo/health" ]]; then
    http_code="${MOCK_CURL_HTTP_CODE_API:-$http_code}"
    exit_code="${MOCK_CURL_EXIT_CODE_API:-$exit_code}"
fi

if [ "$exit_code" -ne 0 ]; then
    printf 'simulated transport failure for %s\n' "$url" >&2
    exit "$exit_code"
fi

printf '%s' "$http_code"
MOCK
    chmod +x "$mock_path"
}

run_health_check() {
    local tmp_dir="$1"
    shift

    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$@" \
        bash "$CHECK_SCRIPT" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

require_owner_script() {
    if [ -f "$CHECK_SCRIPT" ]; then
        pass "outside-AWS health owner script exists"
    else
        fail "outside-AWS health owner script exists"
        return 1
    fi

    if [ -x "$CHECK_SCRIPT" ]; then
        pass "outside-AWS health owner script is executable"
    else
        fail "outside-AWS health owner script is executable"
        return 1
    fi
}

test_green_path_probes_both_targets() {
    if ! require_owner_script; then
        return
    fi

    local tmp_dir call_log args_log call_count calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    mkdir -p "$tmp_dir/bin"
    call_log="$tmp_dir/curl_calls.log"
    args_log="$tmp_dir/curl_args.log"
    : > "$call_log"
    : > "$args_log"

    write_curl_mock "$tmp_dir/bin/curl"

    run_health_check "$tmp_dir" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$args_log" \
        "MOCK_CURL_HTTP_CODE_CLOUD=200" \
        "MOCK_CURL_HTTP_CODE_API=204"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "outside-AWS helper should exit 0 when both targets are healthy"

    calls="$(cat "$call_log" 2>/dev/null || true)"
    call_count="$(wc -l < "$call_log" | tr -d '[:space:]')"

    assert_eq "$call_count" "2" \
        "outside-AWS helper should probe exactly two targets"
    assert_contains "$calls" "https://cloud.flapjack.foo/health" \
        "outside-AWS helper should probe cloud health endpoint"
    assert_contains "$calls" "https://api.flapjack.foo/health" \
        "outside-AWS helper should probe api health endpoint"
}

test_non_2xx_failure_names_target() {
    if ! require_owner_script; then
        return
    fi

    local tmp_dir call_log combined_output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    mkdir -p "$tmp_dir/bin"
    call_log="$tmp_dir/curl_calls.log"
    : > "$call_log"

    write_curl_mock "$tmp_dir/bin/curl"

    run_health_check "$tmp_dir" \
        "CURL_CALL_LOG=$call_log" \
        "CURL_ARGS_LOG=$tmp_dir/curl_args.log" \
        "MOCK_CURL_HTTP_CODE_CLOUD=200" \
        "MOCK_CURL_HTTP_CODE_API=503"

    if [ "$RUN_EXIT_CODE" -ne 0 ]; then
        pass "outside-AWS helper exits non-zero on non-2xx response"
    else
        fail "outside-AWS helper exits non-zero on non-2xx response"
    fi

    combined_output="$RUN_STDOUT\n$RUN_STDERR"
    assert_contains "$combined_output" "https://api.flapjack.foo/health" \
        "non-2xx failure log should name the failed target"
}

test_transport_failure_names_target() {
    if ! require_owner_script; then
        return
    fi

    local tmp_dir combined_output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    mkdir -p "$tmp_dir/bin"

    write_curl_mock "$tmp_dir/bin/curl"

    run_health_check "$tmp_dir" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "CURL_ARGS_LOG=$tmp_dir/curl_args.log" \
        "MOCK_CURL_EXIT_CODE_CLOUD=28"

    if [ "$RUN_EXIT_CODE" -ne 0 ]; then
        pass "outside-AWS helper exits non-zero on transport failure"
    else
        fail "outside-AWS helper exits non-zero on transport failure"
    fi

    combined_output="$RUN_STDOUT\n$RUN_STDERR"
    assert_contains "$combined_output" "https://cloud.flapjack.foo/health" \
        "transport failure log should name the failed target"
}

main() {
    echo "=== outside_aws_health_check_test.sh ==="
    echo ""

    test_green_path_probes_both_targets
    test_non_2xx_failure_names_target
    test_transport_failure_names_target

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
