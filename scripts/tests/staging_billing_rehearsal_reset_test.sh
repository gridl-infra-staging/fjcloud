#!/usr/bin/env bash
# Red-first contract tests for the rehearsal reset path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/staging_billing_rehearsal_harness.sh
source "$SCRIPT_DIR/lib/staging_billing_rehearsal_harness.sh"

TEST_TENANT_ID="11111111-1111-1111-1111-111111111111"
OTHER_TENANT_ID="22222222-2222-2222-2222-222222222222"

artifact_dir_from_stdout() {
    json_field "$RUN_STDOUT" "artifact_dir"
}

assert_reset_blocked_with() {
    local expected_classification="$1"
    local msg_prefix="$2"
    assert_rehearsal_fails_as_blocker
    local artifact_dir
    artifact_dir="$(artifact_dir_from_stdout)"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "$expected_classification" \
        "$msg_prefix should emit stable blocker classification"
}

test_reset_requires_confirm_test_tenant() {
    setup_workspace
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state"
    assert_reset_blocked_with "test_tenant_confirmation_required" \
        "--reset-test-state without --confirm-test-tenant"
}

test_confirm_test_tenant_requires_reset_flag() {
    setup_workspace
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --confirm-test-tenant $TEST_TENANT_ID"
    assert_reset_blocked_with "reset_test_state_required" \
        "--confirm-test-tenant without --reset-test-state"
}

test_reset_rejects_live_mutation_flag_combination() {
    setup_workspace
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-04 --reset-test-state --confirm-live-mutation --confirm-test-tenant $TEST_TENANT_ID"
    assert_reset_blocked_with "reset_mode_live_mutation_conflict" \
        "reset mode with --confirm-live-mutation should fail closed"
}

test_reset_rejects_missing_allowlist() {
    setup_workspace
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID"
    assert_reset_blocked_with "test_tenant_allowlist_missing" \
        "reset path without FJCLOUD_TEST_TENANT_IDS"
}

test_reset_rejects_non_allowlisted_tenant() {
    setup_workspace "$OTHER_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID"
    assert_reset_blocked_with "test_tenant_not_allowlisted" \
        "reset path with non-allowlisted tenant"
}

test_reset_allowlisted_tenant_reaches_reset_orchestration() {
    setup_workspace "$TEST_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=none"

    assert_eq "$RUN_EXIT_CODE" "0" "allowlisted reset gate should permit reset orchestration"
    local artifact_dir calls
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "allowlisted reset should report reset_completed on successful reset flow"
    assert_contains "$calls" "stage4_reset_customer_lookup" \
        "allowlisted reset should reach customer lookup orchestration step"
}

test_reset_accepts_explicit_month_without_live_mutation_confirmation() {
    setup_workspace "$TEST_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-04 --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=none"

    assert_eq "$RUN_EXIT_CODE" "0" "reset mode should accept --month without --confirm-live-mutation"
    local artifact_dir calls
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "reset mode with explicit month should complete successfully"
    assert_contains "$calls" "stage4_reset_invoice_rows" \
        "reset mode with explicit month should still execute reset invoice-row query"
}

test_reset_status_aware_stripe_cleanup_and_db_delete_order() {
    setup_workspace "$TEST_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=clearable_trio" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON={\"data\":[{\"id\":\"si_reset_draft\",\"status\":\"draft\"},{\"id\":\"si_reset_open\",\"status\":\"open\"},{\"id\":\"si_reset_uncollectible\",\"status\":\"uncollectible\"}]}"

    assert_eq "$RUN_EXIT_CODE" "0" "reset should succeed for draft/open/uncollectible stripe invoices"
    local artifact_dir calls db_delete_line stripe_delete_line stripe_void_line
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "successful reset should report reset_completed summary classification"
    assert_contains "$calls" "SELECT stripe_customer_id FROM customers WHERE id = '$TEST_TENANT_ID' /* stage4_reset_customer_lookup */" \
        "reset should look up stripe_customer_id from customers.id"
    assert_contains "$calls" "stripe|invoices list --customer cus_reset_test --limit 100 --format json" \
        "reset should list stripe invoices for the target customer"
    assert_contains "$calls" "stripe|invoices delete si_reset_draft" \
        "draft stripe invoices should be deleted"
    assert_contains "$calls" "stripe|invoices void si_reset_open" \
        "open stripe invoices should be voided"
    assert_contains "$calls" "stripe|invoices void si_reset_uncollectible" \
        "uncollectible stripe invoices should be voided"
    assert_not_contains "$calls" "stripe|invoices void si_reset_draft" \
        "draft stripe invoices must never hit the void path"

    db_delete_line="$(first_call_line_matching '^psql|.*stage4_reset_delete_invoices')"
    stripe_delete_line="$(first_call_line_matching '^stripe|invoices delete si_reset_draft')"
    stripe_void_line="$(first_call_line_matching '^stripe|invoices void si_reset_open')"
    if [ -n "$db_delete_line" ] && [ -n "$stripe_delete_line" ] && [ -n "$stripe_void_line" ] && \
        [ "$db_delete_line" -gt "$stripe_delete_line" ] && [ "$db_delete_line" -gt "$stripe_void_line" ]; then
        pass "DB invoice deletion should happen after stripe cleanup succeeds"
    else
        fail "DB invoice deletion must run after stripe cleanup (delete=${stripe_delete_line:-missing} void=${stripe_void_line:-missing} db=${db_delete_line:-missing})"
    fi
}

test_reset_paid_invoice_deletes_db_rows_without_voiding_paid() {
    setup_workspace "$TEST_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=paid_only" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON={\"data\":[{\"id\":\"si_reset_paid\",\"status\":\"paid\"}]}"

    assert_eq "$RUN_EXIT_CODE" "0" "paid stripe invoices should not block reset completion"
    local artifact_dir calls delete_call
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"
    delete_call="$(grep '^psql|.*stage4_reset_delete_invoices' "$TEST_CALL_LOG" | tail -1 || true)"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "paid stripe invoices should still allow reset_completed classification"
    assert_not_contains "$calls" "stripe|invoices void si_reset_paid" \
        "paid stripe invoices must never hit the void path"
    assert_not_contains "$calls" "stripe|invoices delete si_reset_paid" \
        "paid stripe invoices must never hit the delete path"
    assert_contains "$delete_call" "si_reset_paid" \
        "DB cleanup should include paid stripe invoice IDs"
    assert_contains "$(json_file_field "$artifact_dir/summary.json" "detail")" "paid Stripe invoice(s); paid Stripe invoices were left unchanged" \
        "reset summary detail should report the paid-invoice DB-only cleanup path"
}

test_reset_paid_invoice_without_stripe_id_uses_db_only_cleanup() {
    setup_workspace "$TEST_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=paid_without_stripe_id" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON={\"data\":[]}"

    assert_eq "$RUN_EXIT_CODE" "0" "paid invoice rows without stripe IDs should not block reset completion"
    local artifact_dir calls delete_call
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"
    delete_call="$(grep '^psql|.*stage4_reset_delete_invoices' "$TEST_CALL_LOG" | tail -1 || true)"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "paid invoice rows without stripe IDs should still produce reset_completed"
    assert_not_contains "$calls" "stripe|invoices void" \
        "missing stripe IDs should not trigger stripe void calls"
    assert_not_contains "$calls" "stripe|invoices delete" \
        "missing stripe IDs should not trigger stripe delete calls"
    assert_contains "$delete_call" "inv_local_reset_paid_missing_stripe" \
        "DB cleanup should fall back to deleting by invoice id when stripe_invoice_id is missing"
}

test_reset_draft_invoice_without_stripe_id_uses_db_only_cleanup() {
    setup_workspace "$TEST_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=draft_without_stripe_id" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON={\"data\":[]}"

    assert_eq "$RUN_EXIT_CODE" "0" "draft invoice rows without stripe IDs should not block reset completion"
    local artifact_dir calls delete_call
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"
    delete_call="$(grep '^psql|.*stage4_reset_delete_invoices' "$TEST_CALL_LOG" | tail -1 || true)"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "draft invoice rows without stripe IDs should still produce reset_completed"
    assert_not_contains "$calls" "stripe|invoices void" \
        "missing stripe IDs should not trigger stripe void calls"
    assert_not_contains "$calls" "stripe|invoices delete" \
        "missing stripe IDs should not trigger stripe delete calls"
    assert_contains "$delete_call" "inv_local_reset_draft_missing_stripe" \
        "DB cleanup should fall back to deleting by invoice id when draft stripe_invoice_id is missing"
}

test_reset_db_delete_only_cleared_stripe_invoice_rows() {
    setup_workspace "$TEST_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=draft_and_missing_status" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON={\"data\":[{\"id\":\"si_reset_draft\",\"status\":\"draft\"}]}"

    assert_reset_blocked_with "reset_stripe_invoice_missing" \
        "reset path with a DB row whose stripe invoice is missing from stripe list"

    local delete_call
    delete_call="$(grep '^psql|.*stage4_reset_delete_invoices' "$TEST_CALL_LOG" | tail -1 || true)"
    assert_contains "$delete_call" "si_reset_draft" \
        "DB delete should include cleared stripe invoice IDs"
    assert_not_contains "$delete_call" "si_reset_missing" \
        "DB delete must not include stripe invoice IDs that were not cleared"
}

test_reset_second_invocation_is_clean_noop() {
    setup_workspace "$TEST_TENANT_ID"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=clearable_trio" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON={\"data\":[{\"id\":\"si_reset_draft\",\"status\":\"draft\"},{\"id\":\"si_reset_open\",\"status\":\"open\"},{\"id\":\"si_reset_uncollectible\",\"status\":\"uncollectible\"}]}"
    assert_eq "$RUN_EXIT_CODE" "0" "first reset invocation should succeed"

    local first_delete_count first_void_count
    first_delete_count="$(grep -c '^stripe|invoices delete ' "$TEST_CALL_LOG" || true)"
    first_void_count="$(grep -c '^stripe|invoices void ' "$TEST_CALL_LOG" || true)"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=clearable_trio" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON={\"data\":[{\"id\":\"si_reset_draft\",\"status\":\"draft\"},{\"id\":\"si_reset_open\",\"status\":\"open\"},{\"id\":\"si_reset_uncollectible\",\"status\":\"uncollectible\"}]}"
    assert_eq "$RUN_EXIT_CODE" "0" "second reset invocation should succeed as a no-op"

    local second_artifact_dir second_delete_count second_void_count
    second_artifact_dir="$(artifact_dir_from_stdout)"
    second_delete_count="$(grep -c '^stripe|invoices delete ' "$TEST_CALL_LOG" || true)"
    second_void_count="$(grep -c '^stripe|invoices void ' "$TEST_CALL_LOG" || true)"

    assert_eq "$second_delete_count" "$first_delete_count" \
        "second reset no-op should not issue additional stripe delete calls"
    assert_eq "$second_void_count" "$first_void_count" \
        "second reset no-op should not issue additional stripe void calls"
    assert_eq "$(json_file_field "$second_artifact_dir/summary.json" "classification")" "reset_completed" \
        "second reset no-op should still report reset_completed"
}

test_reset_completed_summary_only_on_full_success() {
    setup_workspace "$TEST_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=draft_and_missing_status" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON={\"data\":[{\"id\":\"si_reset_draft\",\"status\":\"draft\"}]}"

    assert_rehearsal_fails_as_blocker
    local artifact_dir
    artifact_dir="$(artifact_dir_from_stdout)"
    assert_not_contains "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "reset_completed summary classification must only be emitted on fully successful resets"
}

echo "=== staging_billing_rehearsal.sh reset-path contract tests (Stage 4) ==="
test_reset_requires_confirm_test_tenant
test_confirm_test_tenant_requires_reset_flag
test_reset_rejects_live_mutation_flag_combination
test_reset_rejects_missing_allowlist
test_reset_rejects_non_allowlisted_tenant
test_reset_allowlisted_tenant_reaches_reset_orchestration
test_reset_accepts_explicit_month_without_live_mutation_confirmation
test_reset_status_aware_stripe_cleanup_and_db_delete_order
test_reset_paid_invoice_deletes_db_rows_without_voiding_paid
test_reset_paid_invoice_without_stripe_id_uses_db_only_cleanup
test_reset_draft_invoice_without_stripe_id_uses_db_only_cleanup
test_reset_db_delete_only_cleared_stripe_invoice_rows
test_reset_second_invocation_is_clean_noop
test_reset_completed_summary_only_on_full_success
run_test_summary
