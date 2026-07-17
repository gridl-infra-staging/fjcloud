#!/usr/bin/env bash
# Contract tests for the cold-customer journey CLI probe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/canary/contracts/cold_customer_journey_walkthrough.sh"

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

test_default_index_region_matches_staging_region_contract() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    unset CANARY_INDEX_REGION
    # shellcheck source=../canary/contracts/cold_customer_journey_walkthrough.sh
    source "$PROBE_SCRIPT"

    cold_customer_parse_args --dry-run --evidence-dir "$tmp_dir/evidence"
    cold_customer_prepare_environment

    assert_eq "$CANARY_INDEX_REGION" "us-east-1" \
        "default index region should use the staging API's canonical region ID"
}

test_explicit_index_region_override_is_preserved() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    CANARY_INDEX_REGION="eu-west-1"
    # shellcheck source=../canary/contracts/cold_customer_journey_walkthrough.sh
    source "$PROBE_SCRIPT"

    cold_customer_parse_args --dry-run --evidence-dir "$tmp_dir/evidence"
    cold_customer_prepare_environment

    assert_eq "$CANARY_INDEX_REGION" "eu-west-1" \
        "explicit index region override should be preserved"
}

test_default_inbox_domain_matches_ses_inbound_contract() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    unset CANARY_TEST_INBOX_DOMAIN
    unset TEST_INBOX_DOMAIN
    # shellcheck source=../canary/contracts/cold_customer_journey_walkthrough.sh
    source "$PROBE_SCRIPT"

    cold_customer_parse_args --dry-run --evidence-dir "$tmp_dir/evidence"
    cold_customer_prepare_environment

    assert_eq "$CANARY_TEST_INBOX_DOMAIN" "test.flapjack.foo" \
        "default inbox domain should match SES inbound routing (test.flapjack.foo)"
}

test_dry_run_inbox_stub_keeps_ses_inbound_domain() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    unset CANARY_TEST_INBOX_DOMAIN
    unset TEST_INBOX_DOMAIN
    # shellcheck source=../canary/contracts/cold_customer_journey_walkthrough.sh
    source "$PROBE_SCRIPT"

    cold_customer_parse_args --dry-run --evidence-dir "$tmp_dir/evidence"
    cold_customer_prepare_environment
    cold_customer_install_dry_run_inbox_stubs

    assert_eq "$CANARY_TEST_INBOX_DOMAIN" "test.flapjack.foo" \
        "dry-run inbox stub should preserve SES inbound routing domain before signup"
}

test_default_search_retry_budget_widened() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    unset COLD_CUSTOMER_SEARCH_MAX_ATTEMPTS
    unset COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS
    # shellcheck source=../canary/contracts/cold_customer_journey_walkthrough.sh
    source "$PROBE_SCRIPT"

    cold_customer_parse_args --dry-run --evidence-dir "$tmp_dir/evidence"
    cold_customer_prepare_environment

    assert_eq "$COLD_CUSTOMER_SEARCH_MAX_ATTEMPTS" "8" \
        "default search max attempts should be 8"
    assert_eq "$COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS" "2" \
        "default search retry sleep should be 2 seconds"
}

test_search_retry_budget_overrides_preserved() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    COLD_CUSTOMER_SEARCH_MAX_ATTEMPTS=3
    COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS=5
    # shellcheck source=../canary/contracts/cold_customer_journey_walkthrough.sh
    source "$PROBE_SCRIPT"

    cold_customer_parse_args --dry-run --evidence-dir "$tmp_dir/evidence"
    cold_customer_prepare_environment

    assert_eq "$COLD_CUSTOMER_SEARCH_MAX_ATTEMPTS" "3" \
        "explicit search max attempts override should be preserved"
    assert_eq "$COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS" "5" \
        "explicit search retry sleep override should be preserved"
}

test_search_step_preserves_live_response_body() {
    local tmp_dir search_body register_body search_evidence register_evidence
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    # shellcheck source=../canary/contracts/cold_customer_journey_walkthrough.sh
    source "$PROBE_SCRIPT"

    cold_customer_parse_args --dry-run --evidence-dir "$tmp_dir/evidence"
    cold_customer_prepare_environment

    search_body='{"hits":[{"objectID":"doc-0","title":"Document 0","body":"cold-seed body","_highlightResult":{"body":{"value":"<em>cold-seed</em>"}}}],"nbHits":1,"query":"cold-seed","serverUsed":"ip-10-0-1-221.ec2.internal","processingTimingsMS":{"search":18938}}'
    HTTP_RESPONSE_CODE=200
    HTTP_RESPONSE_BODY="$search_body"
    cold_customer_append_step_evidence "search_index" "fail" "seeded_record_missing" 12
    search_evidence="$(cat "$COLD_CUSTOMER_STEPS_FILE")"

    assert_contains "$search_evidence" "\"response_body\"" \
        "search step evidence should include the live response body"
    assert_contains "$search_evidence" "cold-seed" \
        "search step evidence should preserve the live response payload"
    assert_not_contains "$search_evidence" "serverUsed" \
        "search step evidence should redact backend-only host metadata"
    assert_not_contains "$search_evidence" "_highlightResult" \
        "search step evidence should redact verbose per-hit internals"

    : > "$COLD_CUSTOMER_STEPS_FILE"
    register_body='{"token":"secret-token","customer_id":"cust_123"}'
    HTTP_RESPONSE_CODE=201
    HTTP_RESPONSE_BODY="$register_body"
    cold_customer_append_step_evidence "register" "pass" "" 9
    register_evidence="$(cat "$COLD_CUSTOMER_STEPS_FILE")"

    assert_not_contains "$register_evidence" "secret-token" \
        "non-search step evidence should not persist sensitive response bodies"
}

test_summary_records_current_probe_sha() {
    local tmp_dir expected_sha summary_json
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    # shellcheck source=../canary/contracts/cold_customer_journey_walkthrough.sh
    source "$PROBE_SCRIPT"

    cold_customer_parse_args --dry-run --evidence-dir "$tmp_dir/evidence"
    cold_customer_prepare_environment

    CANARY_CUSTOMER_ID="cust_summary"
    COLD_CUSTOMER_VERIFIED=true
    CANARY_INDEX_NAME="cold-customer-proof"
    COLD_CUSTOMER_BATCH_ACCEPTED=5
    COLD_CUSTOMER_SEEDED_RECORD_OBJECT_ID="doc-0"
    COLD_CUSTOMER_SEEDED_RECORD_TITLE="Document 0"
    cold_customer_write_summary "pass" "" ""

    expected_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    summary_json="$(cat "$COLD_CUSTOMER_SUMMARY_FILE")"

    assert_contains "$summary_json" "\"probe_sha\": \"$expected_sha\"" \
        "summary evidence should record the current repo HEAD"
}

test_default_index_region_matches_staging_region_contract
test_explicit_index_region_override_is_preserved
test_default_inbox_domain_matches_ses_inbound_contract
test_dry_run_inbox_stub_keeps_ses_inbound_domain
test_default_search_retry_budget_widened
test_search_retry_budget_overrides_preserved
test_search_step_preserves_live_response_body
test_summary_records_current_probe_sha

if [ "$FAIL_COUNT" -ne 0 ]; then
    echo "cold_customer_journey_walkthrough_test: $FAIL_COUNT failure(s), $PASS_COUNT pass(es)" >&2
    exit 1
fi

echo "cold_customer_journey_walkthrough_test: all $PASS_COUNT test(s) passed"
