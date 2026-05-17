#!/usr/bin/env bash
# Tests for scripts/validate_customer_quickstart.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/validate_customer_quickstart.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"
# shellcheck disable=SC1091
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

run_target() {
    local tmp_dir="$1"
    shift

    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"
    local env_file="$tmp_dir/env.list"
    : > "$env_file"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            *=*)
                printf '%s\n' "$1" >> "$env_file"
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
    done

    RUN_EXIT_CODE=0
    # shellcheck disable=SC2046
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        REPO_ROOT="$REPO_ROOT" \
        $(cat "$env_file" 2>/dev/null) \
        bash "$TARGET_SCRIPT" "$@" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

write_curl_stub_with_status() {
    local path="$1"
    local status_code="$2"
    cat > "$path" <<CURL
#!/usr/bin/env bash
set -euo pipefail
: "\${CURL_CALL_LOG:?CURL_CALL_LOG is required}"
printf '%s\n' "\$*" >> "\$CURL_CALL_LOG"

for arg in "\$@"; do
    if [ "\$arg" = "%{http_code}" ]; then
        printf '${status_code}'
        exit 0
    fi
done
printf 'stub response\n'
CURL
    chmod +x "$path"
}

write_roundtrip_stub() {
    local path="$1"
    cat > "$path" <<'ROUNDTRIP'
#!/usr/bin/env bash
set -euo pipefail
: "${ROUNDTRIP_CALL_LOG:?ROUNDTRIP_CALL_LOG is required}"
printf 'roundtrip|%s\n' "$*" >> "$ROUNDTRIP_CALL_LOG"
exit 0
ROUNDTRIP
    chmod +x "$path"
}

write_customer_loop_stub() {
    local path="$1"
    cat > "$path" <<'CANARY'
#!/usr/bin/env bash
set -euo pipefail
log() { :; }
mark_failure() { FLOW_FAILED=1; FLOW_FAILURE_STEP="$1"; FLOW_FAILURE_DETAIL="$2"; }
load_canary_env() { :; }
run_signup_step() { printf 'flow|signup\n' >> "${QUICKSTART_FLOW_LOG:?}"; }
run_verify_email_step() {
    printf 'flow|verify_email\n' >> "${QUICKSTART_FLOW_LOG:?}"
    printf 'verify_env|domain=%s|s3=%s\n' "${CANARY_TEST_INBOX_DOMAIN:-}" "${CANARY_TEST_INBOX_S3_URI:-}" >> "${QUICKSTART_FLOW_LOG:?}"
}
run_index_create_step() { printf 'flow|index_create\n' >> "${QUICKSTART_FLOW_LOG:?}"; }
run_index_search_step() { printf 'flow|index_search\n' >> "${QUICKSTART_FLOW_LOG:?}"; }
run_delete_index_step() { printf 'flow|delete_index\n' >> "${QUICKSTART_FLOW_LOG:?}"; }
run_delete_account_step() { printf 'flow|delete_account\n' >> "${QUICKSTART_FLOW_LOG:?}"; }
run_admin_cleanup_step() { printf 'flow|admin_cleanup\n' >> "${QUICKSTART_FLOW_LOG:?}"; }
run_customer_loop() {
    run_signup_step || return 1
    run_verify_email_step || return 1
    run_index_create_step || return 1
    run_index_search_step || return 1
    run_delete_index_step || return 1
    run_delete_account_step || return 1
    run_admin_cleanup_step || return 1
}
cleanup_after_flow() { :; }
CANARY
    chmod +x "$path"
}

setup_contract_stubs() {
    local tmp_dir="$1"
    mkdir -p "$tmp_dir/bin" "$tmp_dir/scripts/canary"
    : > "$tmp_dir/curl_calls.log"
    : > "$tmp_dir/roundtrip_calls.log"
    : > "$tmp_dir/flow_calls.log"

    write_curl_stub_with_status "$tmp_dir/bin/curl" "200"
    write_roundtrip_stub "$tmp_dir/scripts/validate_inbound_email_roundtrip.sh"
    write_customer_loop_stub "$tmp_dir/scripts/canary/customer_loop_synthetic.sh"
}

combined_output() {
    printf '%s\n%s\n' "$RUN_STDOUT" "$RUN_STDERR"
}

test_usage_errors_for_missing_or_invalid_mode() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    run_target "$tmp_dir"
    output="$(combined_output)"
    assert_eq "$RUN_EXIT_CODE" "2" "missing mode should exit 2"
    assert_contains "$output" "Usage:" "missing mode should print usage"

    run_target "$tmp_dir" -- invalid
    output="$(combined_output)"
    assert_eq "$RUN_EXIT_CODE" "2" "invalid mode should exit 2"
    assert_contains "$output" "Usage:" "invalid mode should print usage"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_full_flow_modes_require_roundtrip_prereqs() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        -- staging
    output="$(combined_output)"
    assert_eq "$RUN_EXIT_CODE" "2" "staging full-flow should fail fast when roundtrip env is missing"
    assert_contains "$output" "SES_FROM_ADDRESS" "staging failure should name SES_FROM_ADDRESS"
    assert_contains "$output" "INBOUND_ROUNDTRIP_S3_URI" "staging failure should name INBOUND_ROUNDTRIP_S3_URI"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        -- prod
    output="$(combined_output)"
    assert_eq "$RUN_EXIT_CODE" "2" "prod full-flow should fail fast when roundtrip env is missing"
    assert_contains "$output" "SES_REGION" "prod failure should name SES_REGION"
    assert_contains "$output" "INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN" "prod failure should name INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_prod_contract_only_skips_full_flow_prereqs() {
    local tmp_dir output curl_calls roundtrip_calls flow_calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        -- prod --contract-only
    output="$(combined_output)"

    assert_eq "$RUN_EXIT_CODE" "0" "prod --contract-only should succeed without full-flow env"
    assert_contains "$output" "contract-only" "contract-only mode should announce skipped full-flow"

    curl_calls="$(cat "$tmp_dir/curl_calls.log" 2>/dev/null || true)"
    roundtrip_calls="$(cat "$tmp_dir/roundtrip_calls.log" 2>/dev/null || true)"
    flow_calls="$(cat "$tmp_dir/flow_calls.log" 2>/dev/null || true)"

    assert_contains "$curl_calls" "/health" "contract-only should probe /health"
    assert_contains "$curl_calls" "/docs" "contract-only should probe /docs"
    assert_contains "$curl_calls" "/auth/register" "contract-only should include signup endpoint reachability probe"
    assert_contains "$curl_calls" "/auth/verify-email" "contract-only should include verify-email endpoint reachability probe"
    assert_contains "$curl_calls" "/indexes/contract-check/search" "contract-only should include search endpoint reachability probe"

    assert_eq "$roundtrip_calls" "" "contract-only should not invoke inbound roundtrip"
    assert_eq "$flow_calls" "" "contract-only should not run signup/verify/index mutation seams"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_contract_only_fails_on_route_errors() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    # Replace curl stub with one returning 404 for all endpoints
    write_curl_stub_with_status "$tmp_dir/bin/curl" "404"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        -- prod --contract-only
    output="$(combined_output)"
    assert_ne "$RUN_EXIT_CODE" "0" "contract-only should fail when endpoints return 404"
    assert_contains "$output" "404" "contract-only failure should mention the HTTP status"

    # Replace curl stub with one returning 500
    write_curl_stub_with_status "$tmp_dir/bin/curl" "500"
    : > "$tmp_dir/curl_calls.log"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        -- prod --contract-only
    output="$(combined_output)"
    assert_ne "$RUN_EXIT_CODE" "0" "contract-only should fail when endpoints return 500"
    assert_contains "$output" "500" "contract-only failure should mention the HTTP status"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_contract_only_accepts_405_for_route_presence() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"
    cat > "$tmp_dir/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
: "${CURL_CALL_LOG:?CURL_CALL_LOG is required}"
printf '%s\n' "$*" >> "$CURL_CALL_LOG"
url="${*: -1}"

for arg in "$@"; do
    if [ "$arg" = "%{http_code}" ]; then
        case "$url" in
            */health|*/docs)
                printf '200'
                ;;
            *)
                printf '405'
                ;;
        esac
        exit 0
    fi
done
printf 'stub response\n'
CURL
    chmod +x "$tmp_dir/bin/curl"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        -- prod --contract-only
    output="$(combined_output)"

    assert_eq "$RUN_EXIT_CODE" "0" "contract-only should treat 405 as reachable route"
    assert_contains "$output" "contract-only completed non-destructive contract checks" "success output should confirm contract probe completion"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_full_flow_fails_fast_on_missing_admin_key() {
    local tmp_dir output flow_calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    # Provide all roundtrip prereqs but NOT ADMIN_KEY
    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        "SES_FROM_ADDRESS=test@example.com" \
        "SES_REGION=us-east-1" \
        "INBOUND_ROUNDTRIP_S3_URI=s3://bucket/prefix" \
        "INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN=inbound.example.com" \
        -- staging
    output="$(combined_output)"

    assert_ne "$RUN_EXIT_CODE" "0" "staging should fail when ADMIN_KEY is missing"
    assert_contains "$output" "ADMIN_KEY" "failure should name ADMIN_KEY"

    # Verify no flow steps were invoked (fail-fast before mutation)
    flow_calls="$(cat "$tmp_dir/flow_calls.log" 2>/dev/null || true)"
    assert_eq "$flow_calls" "" "no flow steps should run when ADMIN_KEY is missing"

    # FLAPJACK_ADMIN_KEY should satisfy the same prerequisite
    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        "SES_FROM_ADDRESS=test@example.com" \
        "SES_REGION=us-east-1" \
        "INBOUND_ROUNDTRIP_S3_URI=s3://bucket/prefix" \
        "INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN=inbound.example.com" \
        "FLAPJACK_ADMIN_KEY=test-key" \
        -- staging
    output="$(combined_output)"
    assert_ne "$RUN_EXIT_CODE" "2" "staging should pass prereqs when FLAPJACK_ADMIN_KEY is set"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_full_flow_modes_require_explicit_api_url() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        -- staging
    output="$(combined_output)"
    assert_eq "$RUN_EXIT_CODE" "2" "staging should fail fast when API_URL is unset"
    assert_contains "$output" "API_URL" "staging failure should name API_URL requirement"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        -- prod
    output="$(combined_output)"
    assert_eq "$RUN_EXIT_CODE" "2" "prod should fail fast when API_URL is unset"
    assert_contains "$output" "API_URL" "prod failure should name API_URL requirement"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_full_flow_bridges_roundtrip_inbox_env_to_canary_owner() {
    local tmp_dir output flow_calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        "SES_FROM_ADDRESS=test@example.com" \
        "SES_REGION=us-east-1" \
        "INBOUND_ROUNDTRIP_S3_URI=s3://bucket/stage3-prefix" \
        "INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN=mail.stage3.example.com" \
        "FLAPJACK_ADMIN_KEY=test-key" \
        -- staging
    assert_eq "$RUN_EXIT_CODE" "0" "staging full-flow should succeed when prerequisites are present"

    flow_calls="$(cat "$tmp_dir/flow_calls.log" 2>/dev/null || true)"
    assert_contains "$flow_calls" "verify_env|domain=mail.stage3.example.com|s3=s3://bucket/stage3-prefix" "verify-email step should read bridged inbox values"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_stub_root_override_is_test_only() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        -- prod --contract-only
    output="$(combined_output)"

    assert_eq "$RUN_EXIT_CODE" "2" "stub-root override should fail closed without explicit test gate"
    assert_contains "$output" "QUICKSTART_STUB_ROOT is test-only" "stub-root failure should explain the test-only gate"

    trap - RETURN
    rm -rf "$tmp_dir"
}

echo "=== validate_customer_quickstart.sh tests ==="
test_usage_errors_for_missing_or_invalid_mode
test_full_flow_modes_require_roundtrip_prereqs
test_prod_contract_only_skips_full_flow_prereqs
test_contract_only_fails_on_route_errors
test_contract_only_accepts_405_for_route_presence
test_full_flow_fails_fast_on_missing_admin_key
test_full_flow_modes_require_explicit_api_url
test_full_flow_bridges_roundtrip_inbox_env_to_canary_owner
test_stub_root_override_is_test_only

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
