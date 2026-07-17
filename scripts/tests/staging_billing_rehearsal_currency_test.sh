#!/usr/bin/env bash
# Red-first deployable-currency contract tests for scripts/staging_billing_rehearsal.sh.
#
# Extracted from staging_billing_rehearsal_test.sh so that file stays under the
# 800-line repo hard limit while the currency-preflight contract group grows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/staging_billing_rehearsal_harness.sh
source "$SCRIPT_DIR/lib/staging_billing_rehearsal_harness.sh"

test_deployable_currency_drift_refuses_before_live_rehearsal_paths() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_DEPLOYED_DEV_SHA=1111111111111111111111111111111111111111" \
        "REHEARSAL_MOCK_TARGET_DEV_SHA=2222222222222222222222222222222222222222" \
        "REHEARSAL_MOCK_DEPLOYABLE_CURRENCY=deployable_drift"

    assert_rehearsal_fails_as_blocker

    local artifact_dir calls health_line psql_line billing_line
    artifact_dir="$(find_artifact_dir)"
    calls="$(cat "$TEST_CALL_LOG")"
    health_line="$(first_call_line_matching '^curl|.*/health')"
    psql_line="$(first_call_line_matching '^psql|.*SELECT COUNT(\*) FROM usage_records')"
    billing_line="$(first_call_line_matching '^curl|.*/admin/billing/run')"

    assert_eq "$(json_file_path_field "$artifact_dir/summary.json" "classification")" "deployable_currency_drift" \
        "deployable drift should emit a distinct refusal classification"
    assert_eq "$(json_file_path_field "$artifact_dir/summary.json" "dev_sha")" "1111111111111111111111111111111111111111" \
        "drift refusal summary should record the proved deployed dev_sha"
    assert_eq "$(json_file_path_field "$artifact_dir/summary.json" "deployable_currency.deployable_drift")" "true" \
        "drift refusal summary should record structured deployable_drift=true"
    assert_contains "$calls" "dry_run|" \
        "deployable drift should be classified through the existing preflight owner seam"
    assert_eq "$health_line" "" \
        "deployable drift should refuse before health probing"
    assert_eq "$psql_line" "" \
        "deployable drift should refuse before metering evidence"
    assert_eq "$billing_line" "" \
        "deployable drift should refuse before live billing mutation"
}

test_success_summary_records_deployable_currency_verdict() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_DEPLOYED_DEV_SHA=3333333333333333333333333333333333333333" \
        "REHEARSAL_MOCK_TARGET_DEV_SHA=3333333333333333333333333333333333333333" \
        "REHEARSAL_MOCK_DEPLOYABLE_CURRENCY=clean"

    assert_rehearsal_succeeds

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"

    assert_eq "$(json_file_path_field "$artifact_dir/summary.json" "dev_sha")" "3333333333333333333333333333333333333333" \
        "success summary should record the proved deployed dev_sha"
    assert_eq "$(json_file_path_field "$artifact_dir/summary.json" "deployable_currency.deployable_drift")" "false" \
        "success summary should record structured deployable_drift=false"
    assert_eq "$(json_file_path_field "$artifact_dir/summary.json" "deployable_currency.doc_only_ahead")" "false" \
        "success summary should record structured doc_only_ahead=false"
}

echo "=== staging_billing_rehearsal.sh deployable-currency contract tests ==="
TESTS=(test_deployable_currency_drift_refuses_before_live_rehearsal_paths test_success_summary_records_deployable_currency_verdict)
for test_fn in "${TESTS[@]}"; do "$test_fn"; done
run_test_summary
