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
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/tests/lib/validate_customer_quickstart_fixtures.sh"

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
        FJCLOUD_SECRET_FILE="$tmp_dir/no_secret.env" \
        $(cat "$env_file" 2>/dev/null) \
        bash "$TARGET_SCRIPT" "$@" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
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
    write_fixture_docs "$tmp_dir" "complete"
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
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
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
    local indexes_root_probed=0
    grep -Eq '/indexes$' "$tmp_dir/curl_calls.log" && indexes_root_probed=1
    assert_eq "$indexes_root_probed" "1" "contract-only should include list-indexes endpoint reachability probe"
    assert_contains "$curl_calls" "/indexes/contract-check/batch" "contract-only should include batch endpoint reachability probe"
    assert_contains "$curl_calls" "/indexes/contract-check/search" "contract-only should include search endpoint reachability probe"
    assert_contains "$curl_calls" "/indexes/contract-check/objects/contract-object" "contract-only should include get-object endpoint reachability probe"
    assert_contains "$curl_calls" "/indexes/contract-check/synonyms/contract-synonym" "contract-only should include synonym endpoint reachability probe"
    assert_contains "$curl_calls" "/indexes/contract-check/rules/contract-rule" "contract-only should include rule endpoint reachability probe"

    assert_eq "$roundtrip_calls" "" "contract-only should not invoke inbound roundtrip"
    assert_eq "$flow_calls" "" "contract-only should not run signup/verify/index mutation seams"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_prod_contract_only_probes_documented_http_verbs() {
    local tmp_dir curl_calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        -- prod --contract-only

    assert_eq "$RUN_EXIT_CODE" "0" "prod --contract-only should succeed with documented verb probes"

    curl_calls="$(cat "$tmp_dir/curl_calls.log" 2>/dev/null || true)"
    assert_contains "$curl_calls" "-X POST https://api.example.test/auth/register" "contract-only should probe register with POST"
    assert_contains "$curl_calls" "-X POST https://api.example.test/auth/verify-email" "contract-only should probe verify-email with POST"
    assert_contains "$curl_calls" "-X GET https://api.example.test/indexes" "contract-only should probe list indexes with GET"
    assert_contains "$curl_calls" "-X POST https://api.example.test/indexes" "contract-only should probe create index with POST"
    assert_contains "$curl_calls" "-X POST https://api.example.test/indexes/contract-check/batch" "contract-only should probe batch with POST"
    assert_contains "$curl_calls" "-X POST https://api.example.test/indexes/contract-check/search" "contract-only should probe search with POST"
    assert_contains "$curl_calls" "-X GET https://api.example.test/indexes/contract-check/objects/contract-object" "contract-only should probe get-object with GET"
    assert_contains "$curl_calls" "-X DELETE https://api.example.test/indexes/contract-check/objects/contract-object" "contract-only should probe delete-object with DELETE"
    assert_contains "$curl_calls" "-X PUT https://api.example.test/indexes/contract-check/synonyms/contract-synonym" "contract-only should probe save-synonym with PUT"
    assert_contains "$curl_calls" "-X PUT https://api.example.test/indexes/contract-check/rules/contract-rule" "contract-only should probe save-rule with PUT"
    assert_not_contains "$curl_calls" "-X OPTIONS" "contract-only should not use OPTIONS for documented verb coverage"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_doc_marker_inventory_is_exact() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        "API_URL=https://api.example.test" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        -- prod --contract-only
    output="$(combined_output)"

    assert_eq "$RUN_EXIT_CODE" "0" "complete fixture docs should satisfy marker inventory"
    assert_contains "$output" "quickstart markers: auth_register auth_verify_email indexes_create indexes_batch_add_object indexes_search" "quickstart inventory should be exact"
    assert_contains "$output" "migration markers: migration_indexes_list migration_indexes_create migration_indexes_batch_add_object migration_indexes_search migration_indexes_get_object migration_indexes_batch_update_object migration_indexes_delete_object migration_indexes_save_synonym migration_indexes_save_rule" "migration inventory should be exact"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_doc_marker_overrides_are_test_only() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        "API_URL=https://api.example.test" \
        -- prod --contract-only
    output="$(combined_output)"

    assert_eq "$RUN_EXIT_CODE" "2" "doc override should fail closed without explicit test gate"
    assert_contains "$output" "doc overrides are test-only" "doc override failure should explain the test-only gate"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_doc_marker_validation_rejects_unknown_marker() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"
    write_fixture_docs "$tmp_dir" "unexpected"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        "API_URL=https://api.example.test" \
        -- prod --contract-only
    output="$(combined_output)"

    assert_ne "$RUN_EXIT_CODE" "0" "unknown doc marker should fail validation"
    assert_contains "$output" "unexpected_marker" "unknown marker diagnostic should name the marker"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_doc_marker_validation_rejects_missing_required_case() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"
    write_fixture_docs "$tmp_dir" "missing_migration_rule"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        "API_URL=https://api.example.test" \
        -- prod --contract-only
    output="$(combined_output)"

    assert_ne "$RUN_EXIT_CODE" "0" "missing required marker should fail validation"
    assert_contains "$output" "migration_indexes_save_rule" "missing marker diagnostic should name the case-table ID"
    assert_contains "$output" "migration doc" "missing marker diagnostic should name the required doc"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_doc_marker_validation_rejects_duplicate_marker() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"
    write_fixture_docs "$tmp_dir" "duplicate_quickstart_marker"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        "API_URL=https://api.example.test" \
        -- prod --contract-only
    output="$(combined_output)"

    assert_ne "$RUN_EXIT_CODE" "0" "duplicate quickstart marker should fail validation"
    assert_contains "$output" "duplicate marker 'indexes_search'" "duplicate quickstart diagnostic should name the marker"
    assert_contains "$output" "quickstart doc" "duplicate quickstart diagnostic should name the doc"

    write_fixture_docs "$tmp_dir" "duplicate_migration_marker"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        "API_URL=https://api.example.test" \
        -- prod --contract-only
    output="$(combined_output)"

    assert_ne "$RUN_EXIT_CODE" "0" "duplicate migration marker should fail validation"
    assert_contains "$output" "duplicate marker 'migration_indexes_search'" "duplicate migration diagnostic should name the marker"
    assert_contains "$output" "migration doc" "duplicate migration diagnostic should name the doc"

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

test_contract_only_rejects_405_for_documented_verbs() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"
    write_curl_stub_health_success_other_status "$tmp_dir/bin/curl" "405"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        -- prod --contract-only
    output="$(combined_output)"

    assert_ne "$RUN_EXIT_CODE" "0" "contract-only should fail when a documented verb returns 405"
    assert_contains "$output" "405" "contract-only verb failure should mention method-not-allowed status"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_contract_only_accepts_auth_failures_for_documented_verbs() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"
    write_curl_stub_health_success_other_status "$tmp_dir/bin/curl" "401"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "API_URL=https://api.example.test" \
        "CURL_CALL_LOG=$tmp_dir/curl_calls.log" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        -- prod --contract-only
    output="$(combined_output)"

    assert_eq "$RUN_EXIT_CODE" "0" "contract-only should treat auth failures as documented method reachability"
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

test_full_flow_calls_quickstart_and_migration_cases_in_order() {
    local tmp_dir flow_calls expected_flow
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        "API_URL=https://api.example.test" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        "SES_FROM_ADDRESS=test@example.com" \
        "SES_REGION=us-east-1" \
        "INBOUND_ROUNDTRIP_S3_URI=s3://bucket/stage4-prefix" \
        "INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN=mail.stage4.example.com" \
        "FLAPJACK_ADMIN_KEY=test-key" \
        -- staging

    assert_eq "$RUN_EXIT_CODE" "0" "staging full-flow should execute migration cases with fixture docs"

    flow_calls="$(cat "$tmp_dir/flow_calls.log" 2>/dev/null || true)"
    expected_flow="$(cat <<'EXPECTED'
flow|signup
flow|verify_email
verify_env|domain=mail.stage4.example.com|s3=s3://bucket/stage4-prefix
flow|index_create
flow|index_batch
flow|index_search
http|GET|/indexes
http|POST|/indexes/canary-index/batch
http|POST|/indexes/canary-index/search
http|GET|/indexes/canary-index/objects/obj-1
http|POST|/indexes/canary-index/batch
http|POST|/indexes/canary-index/search
http|DELETE|/indexes/canary-index/objects/obj-2
http|GET|/indexes/canary-index/objects/obj-2
http|PUT|/indexes/canary-index/synonyms/laptop-syn
http|PUT|/indexes/canary-index/rules/boost-shoes
flow|delete_index
flow|delete_account
flow|admin_cleanup
EXPECTED
)"
    assert_eq "$flow_calls" "$expected_flow" "full flow should call quickstart, migration, and teardown cases in order"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_full_flow_logs_successful_migration_cases() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        "API_URL=https://api.example.test" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        "SES_FROM_ADDRESS=test@example.com" \
        "SES_REGION=us-east-1" \
        "INBOUND_ROUNDTRIP_S3_URI=s3://bucket/stage4-prefix" \
        "INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN=mail.stage4.example.com" \
        "FLAPJACK_ADMIN_KEY=test-key" \
        -- staging
    output="$(combined_output)"

    assert_eq "$RUN_EXIT_CODE" "0" "staging full-flow should pass before checking migration logs"
    assert_contains "$output" "migration case succeeded: migration_indexes_list" "full-flow output should log list-indexes migration success"
    assert_contains "$output" "migration case succeeded: migration_indexes_create" "full-flow output should log create-index migration success"
    assert_contains "$output" "migration case succeeded: migration_indexes_batch_add_object" "full-flow output should log batch-add migration success"
    assert_contains "$output" "migration case succeeded: migration_indexes_search" "full-flow output should log migration search success"
    assert_contains "$output" "migration case succeeded: migration_indexes_get_object" "full-flow output should log get-object migration success"
    assert_contains "$output" "migration case succeeded: migration_indexes_batch_update_object" "full-flow output should log batch-update migration success"
    assert_contains "$output" "migration case succeeded: migration_indexes_delete_object" "full-flow output should log delete-object migration success"
    assert_contains "$output" "migration case succeeded: migration_indexes_save_synonym" "full-flow output should log save-synonym migration success"
    assert_contains "$output" "migration case succeeded: migration_indexes_save_rule" "full-flow output should log save-rule migration success"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_migration_search_cases_retry_visibility_lag() {
    local tmp_dir flow_calls search_call_count
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        "QUICKSTART_SEARCH_LAG_ONCE=1" \
        "API_URL=https://api.example.test" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        "SES_FROM_ADDRESS=test@example.com" \
        "SES_REGION=us-east-1" \
        "INBOUND_ROUNDTRIP_S3_URI=s3://bucket/stage4-prefix" \
        "INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN=mail.stage4.example.com" \
        "FLAPJACK_ADMIN_KEY=test-key" \
        -- staging

    assert_eq "$RUN_EXIT_CODE" "0" "migration searches should retry through normal index visibility lag"

    flow_calls="$(cat "$tmp_dir/flow_calls.log" 2>/dev/null || true)"
    search_call_count="$(printf '%s\n' "$flow_calls" | grep -c '^http|POST|/indexes/canary-index/search$')"
    assert_eq "$search_call_count" "4" "migration add and update searches should each retry after one empty result"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_migration_get_object_requires_promised_content() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        "QUICKSTART_STALE_GET_OBJECT=1" \
        "API_URL=https://api.example.test" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        "SES_FROM_ADDRESS=test@example.com" \
        "SES_REGION=us-east-1" \
        "INBOUND_ROUNDTRIP_S3_URI=s3://bucket/stage4-prefix" \
        "INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN=mail.stage4.example.com" \
        "FLAPJACK_ADMIN_KEY=test-key" \
        -- staging
    output="$(combined_output)"

    assert_ne "$RUN_EXIT_CODE" "0" "get-object case should reject stale object content"
    assert_contains "$output" "title=First" "get-object failure should name the expected title"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_migration_delete_object_requires_deleted_result() {
    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_contract_stubs "$tmp_dir"

    run_target "$tmp_dir" \
        "QUICKSTART_ALLOW_STUB_ROOT=1" \
        "QUICKSTART_STUB_ROOT=$tmp_dir" \
        "QUICKSTART_ALLOW_DOC_OVERRIDES=1" \
        "QUICKSTART_DOC_PATH=$tmp_dir/customer_quickstart.md" \
        "QUICKSTART_MIGRATION_DOC_PATH=$tmp_dir/migrating_from_algolia.md" \
        "QUICKSTART_NOOP_DELETE_OBJECT=1" \
        "API_URL=https://api.example.test" \
        "ROUNDTRIP_CALL_LOG=$tmp_dir/roundtrip_calls.log" \
        "QUICKSTART_FLOW_LOG=$tmp_dir/flow_calls.log" \
        "SES_FROM_ADDRESS=test@example.com" \
        "SES_REGION=us-east-1" \
        "INBOUND_ROUNDTRIP_S3_URI=s3://bucket/stage4-prefix" \
        "INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN=mail.stage4.example.com" \
        "FLAPJACK_ADMIN_KEY=test-key" \
        -- staging
    output="$(combined_output)"

    assert_ne "$RUN_EXIT_CODE" "0" "delete-object case should reject a no-op delete response"
    assert_contains "$output" "objectID=obj-2" "delete-object failure should name the expected deleted object"

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
test_prod_contract_only_probes_documented_http_verbs
test_doc_marker_inventory_is_exact
test_doc_marker_overrides_are_test_only
test_doc_marker_validation_rejects_unknown_marker
test_doc_marker_validation_rejects_missing_required_case
test_doc_marker_validation_rejects_duplicate_marker
test_contract_only_fails_on_route_errors
test_contract_only_rejects_405_for_documented_verbs
test_contract_only_accepts_auth_failures_for_documented_verbs
test_full_flow_fails_fast_on_missing_admin_key
test_full_flow_modes_require_explicit_api_url
test_full_flow_bridges_roundtrip_inbox_env_to_canary_owner
test_full_flow_calls_quickstart_and_migration_cases_in_order
test_full_flow_logs_successful_migration_cases
test_migration_search_cases_retry_visibility_lag
test_migration_get_object_requires_promised_content
test_migration_delete_object_requires_deleted_result
test_stub_root_override_is_test_only

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
