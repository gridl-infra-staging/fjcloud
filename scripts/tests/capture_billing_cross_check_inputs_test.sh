#!/usr/bin/env bash
# Red-first contract tests for scripts/launch/capture_billing_cross_check_inputs.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/staging_billing_rehearsal_harness.sh
source "$SCRIPT_DIR/lib/staging_billing_rehearsal_harness.sh"

INVOICE_ID="e7806ad2-977d-4f4b-9ff9-95c7ddab49e3"

test_capture_emits_stage1_cross_check_bundle_artifacts() {
    setup_workspace

    local bundle_dir="$TEST_WORKSPACE/evidence_bundle"
    run_capture_billing_cross_check_inputs \
        --args "--env staging --invoice-id $INVOICE_ID --bundle-dir $bundle_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "capture script should exit successfully for contract fixture input"
    assert_cross_check_input_artifacts_exist "$bundle_dir"
    assert_eq "$(cat "$bundle_dir/customer_rate_override.json")" "null" \
        "customer_rate_override artifact should use canonical JSON null when no override exists"

    local rate_card_selection_json
    rate_card_selection_json="$(cat "$bundle_dir/rate_card_selection.json")"
    assert_contains "$rate_card_selection_json" "\"selection_basis\":\"invoice_created_at\"" \
        "rate_card_selection should record invoice-time selection basis metadata"
    assert_contains "$rate_card_selection_json" "\"invoice_selection_timestamp\"" \
        "rate_card_selection should persist the invoice-time selection timestamp used for pricing"
    assert_contains "$rate_card_selection_json" "\"invoice_created_at\"" \
        "rate_card_selection should persist invoice created_at for replay provenance"
    assert_contains "$rate_card_selection_json" "\"invoice_paid_at\"" \
        "rate_card_selection should persist invoice paid_at for replay provenance"
    assert_contains "$rate_card_selection_json" "\"override_exists\":false" \
        "rate_card_selection should encode whether a matching override exists for the selected card/window"

    local calls
    calls="$(cat "$TEST_CALL_LOG")"
    assert_contains "$calls" "/fjcloud/staging/database_url" \
        "capture script should hydrate DATABASE_URL through the staging SSM owner path"
    assert_contains "$calls" "stage1_invoice_db_row" \
        "capture script should delegate invoice DB row extraction to shared SQL owners"
    assert_contains "$calls" "stage1_usage_records_provenance" \
        "capture script should delegate usage provenance extraction to shared SQL owners"
}

test_capture_forces_hydrated_database_url_even_when_preexported() {
    setup_workspace

    local bundle_dir="$TEST_WORKSPACE/evidence_bundle"
    local wrong_db_url="postgres://wrong-user:wrong-pass@wrong-host:5432/wrong_db"
    local hydrated_db_url="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev"
    run_capture_billing_cross_check_inputs \
        --args "--env staging --invoice-id $INVOICE_ID --bundle-dir $bundle_dir" \
        "INTEGRATION_DB_URL=" \
        "DATABASE_URL=$wrong_db_url"

    assert_eq "$RUN_EXIT_CODE" "0" "capture should still succeed under fixture data with pre-exported DATABASE_URL"
    local calls
    calls="$(cat "$TEST_CALL_LOG")"
    assert_contains "$calls" "$hydrated_db_url" \
        "capture should force DATABASE_URL from staging hydration before issuing psql queries"
    assert_not_contains "$calls" "$wrong_db_url" \
        "capture should not issue psql queries against a pre-exported non-staging DATABASE_URL"
}

test_capture_uses_invoice_time_bounded_usage_sql_contract() {
    setup_workspace

    local bundle_dir="$TEST_WORKSPACE/evidence_bundle"
    run_capture_billing_cross_check_inputs \
        --args "--env staging --invoice-id $INVOICE_ID --bundle-dir $bundle_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "capture should succeed so SQL delegation can be inspected"
    local calls
    calls="$(cat "$TEST_CALL_LOG")"
    assert_contains "$calls" "ud.date >= i.period_start AND ud.date <= i.period_end" \
        "usage_daily replay query should still stay within the invoice date window"
    assert_contains "$calls" "ud.aggregated_at <= i.created_at" \
        "usage_daily replay query should refuse post-invoice aggregates"
    assert_contains "$calls" "JOIN replay_usage_daily ud" \
        "usage_records provenance query should derive from the same replay_usage_daily slice"
    assert_contains "$calls" "(ur.recorded_at AT TIME ZONE 'utc')::date = ud.date" \
        "usage_records provenance query should stay pinned to the captured replay dates"
    assert_contains "$calls" "ur.recorded_at <= ud.aggregated_at" \
        "usage_records provenance query should refuse raw records beyond each replay aggregate boundary"
    assert_not_contains "$calls" "ur.recorded_at < (i.period_end::timestamp + interval '1 day')" \
        "usage_records provenance query should not fall back to the full invoice period window"
}

test_capture_selects_rate_cards_with_invoice_timestamp_contract() {
    setup_workspace

    local bundle_dir="$TEST_WORKSPACE/evidence_bundle"
    run_capture_billing_cross_check_inputs \
        --args "--env staging --invoice-id $INVOICE_ID --bundle-dir $bundle_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "capture should succeed so rate-card SQL delegation can be inspected"
    local calls
    calls="$(cat "$TEST_CALL_LOG")"
    assert_contains "$calls" "created_at AS selection_timestamp" \
        "rate-card selection query should use invoice created_at as the owner selection timestamp"
    assert_not_contains "$calls" "COALESCE(i.paid_at, i.created_at) AS selection_timestamp" \
        "rate-card selection query should never prefer paid_at over created_at"
    assert_contains "$calls" "rc.effective_from <= i.selection_timestamp" \
        "rate-card selection query should choose historical card by invoice-time timestamp"
    assert_not_contains "$calls" "cro.created_at <= i.selection_timestamp" \
        "override capture query should not infer historical payload from mutable created_at timestamps"
    assert_not_contains "$calls" "COALESCE(i.paid_at, i.created_at)" \
        "no Stage 1 cross-check query should prefer paid_at for pricing selection"
    assert_not_contains "$calls" "to_char(created_at AT TIME ZONE 'utc'" \
        "rate-card selection should preserve exact invoice created_at timestamp precision"
    assert_not_contains "$calls" "to_char(paid_at AT TIME ZONE 'utc'" \
        "rate-card selection should preserve exact invoice paid_at timestamp precision"
    assert_not_contains "$calls" "to_char(selection_timestamp AT TIME ZONE 'utc'" \
        "rate-card selection should preserve exact selection_timestamp precision"
}

test_capture_projects_customer_billing_context_fields_only() {
    setup_workspace

    local bundle_dir="$TEST_WORKSPACE/evidence_bundle"
    run_capture_billing_cross_check_inputs \
        --args "--env staging --invoice-id $INVOICE_ID --bundle-dir $bundle_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "capture should succeed so customer billing context SQL can be inspected"
    local calls
    calls="$(cat "$TEST_CALL_LOG")"
    assert_contains "$calls" "SELECT c.id, c.email, c.billing_plan, c.object_storage_egress_carryforward_cents" \
        "customer billing context query should project only billing replay fields"
    assert_not_contains "$calls" "SELECT c.* FROM customers c" \
        "customer billing context query should not project the full customer row"
}

test_capture_fails_closed_when_override_proof_is_missing() {
    setup_workspace

    local bundle_dir="$TEST_WORKSPACE/evidence_bundle"
    run_capture_billing_cross_check_inputs \
        --args "--env staging --invoice-id $INVOICE_ID --bundle-dir $bundle_dir" \
        "REHEARSAL_MOCK_STAGE1_RATE_CARD_SELECTION_MODE=override_exists" \
        "REHEARSAL_MOCK_STAGE1_OVERRIDE_MODE=none"

    assert_eq "$RUN_EXIT_CODE" "1" "capture should fail closed when override exists without historical payload proof"
    assert_valid_json "$RUN_STDOUT" "override-proof failure output should be valid JSON"
    assert_contains "$RUN_STDOUT" "\"classification\":\"customer_rate_override_missing_historical_proof\"" \
        "override-proof mismatch should emit stable fail-closed classification"
    assert_contains "$RUN_STDOUT" "Cannot prove historical override payload" \
        "override-proof mismatch detail should explain why capture failed closed"
}

test_capture_fails_closed_when_override_proof_is_missing_with_spaced_json() {
    setup_workspace

    local bundle_dir="$TEST_WORKSPACE/evidence_bundle"
    run_capture_billing_cross_check_inputs \
        --args "--env staging --invoice-id $INVOICE_ID --bundle-dir $bundle_dir" \
        "REHEARSAL_MOCK_STAGE1_RATE_CARD_SELECTION_MODE=override_exists_spaced" \
        "REHEARSAL_MOCK_STAGE1_OVERRIDE_MODE=none"

    assert_eq "$RUN_EXIT_CODE" "1" "capture should fail closed when spaced-json override_exists=true has no historical payload proof"
    assert_valid_json "$RUN_STDOUT" "spaced-json override-proof failure output should be valid JSON"
    assert_contains "$RUN_STDOUT" "\"classification\":\"customer_rate_override_missing_historical_proof\"" \
        "spaced-json override-proof mismatch should emit stable fail-closed classification"
}

test_capture_preserves_exact_invoice_timestamps_across_artifacts() {
    setup_workspace

    local bundle_dir="$TEST_WORKSPACE/evidence_bundle"
    run_capture_billing_cross_check_inputs \
        --args "--env staging --invoice-id $INVOICE_ID --bundle-dir $bundle_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "capture should succeed so timestamp provenance can be validated"
    python3 - "$bundle_dir/invoice_db_row.json" "$bundle_dir/rate_card_selection.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as invoice_file:
    invoice = json.load(invoice_file)
with open(sys.argv[2], encoding="utf-8") as selection_file:
    selection = json.load(selection_file)

assert selection["invoice_created_at"] == invoice["created_at"], (
    "rate_card_selection invoice_created_at must match invoice_db_row created_at exactly"
)
assert selection["invoice_paid_at"] == invoice["paid_at"], (
    "rate_card_selection invoice_paid_at must match invoice_db_row paid_at exactly"
)
assert selection["invoice_selection_timestamp"] == invoice["created_at"], (
    "rate_card_selection invoice_selection_timestamp must equal invoice created_at exactly"
)
PY
}

test_capture_rejects_missing_option_values() {
    setup_workspace

    local bundle_dir="$TEST_WORKSPACE/evidence_bundle"
    run_capture_billing_cross_check_inputs \
        --args "--env staging --invoice-id --bundle-dir $bundle_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "capture should fail with usage error when a flag value is missing"
    assert_contains "$RUN_STDOUT" "ERROR: Missing value for --invoice-id" \
        "capture should report which option was missing its required value"
}

echo "=== capture_billing_cross_check_inputs.sh tests ==="
test_capture_emits_stage1_cross_check_bundle_artifacts
test_capture_forces_hydrated_database_url_even_when_preexported
test_capture_uses_invoice_time_bounded_usage_sql_contract
test_capture_selects_rate_cards_with_invoice_timestamp_contract
test_capture_projects_customer_billing_context_fields_only
test_capture_fails_closed_when_override_proof_is_missing
test_capture_fails_closed_when_override_proof_is_missing_with_spaced_json
test_capture_preserves_exact_invoice_timestamps_across_artifacts
test_capture_rejects_missing_option_values
run_test_summary
