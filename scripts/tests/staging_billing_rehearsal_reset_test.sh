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

test_reset_first_runs_reset_before_live_rehearsal() {
    setup_workspace "$TEST_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-first --month 2026-04 --confirm-live-mutation --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=none"

    assert_rehearsal_succeeds
    local artifact_dir reset_line billing_line calls
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"
    reset_line="$(first_call_line_matching 'stage4_reset_customer_lookup')"
    billing_line="$(first_call_line_matching '/admin/billing/run')"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "rehearsal_completed" \
        "reset-first should preserve the live rehearsal completion classification"
    assert_contains "$calls" "stage4_reset_customer_lookup" \
        "reset-first should run the reset owner"
    assert_contains "$calls" "/admin/billing/run" \
        "reset-first should continue to the live billing mutation"
    if [ -n "$reset_line" ] && [ -n "$billing_line" ] && [ "$reset_line" -lt "$billing_line" ]; then
        pass "reset-first should run reset before billing mutation"
    else
        fail "reset-first must run reset before billing mutation (reset=${reset_line:-missing} billing=${billing_line:-missing})"
    fi
}

test_reset_first_limits_repeat_pass_lookup_to_confirmed_tenant() {
    setup_workspace "$TEST_TENANT_ID,$OTHER_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-first --month 2026-04 --confirm-live-mutation --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=none"

    assert_rehearsal_succeeds
    local calls
    calls="$(cat "$TEST_CALL_LOG")"
    assert_contains "$calls" "stage3_existing_same_month_invoice_rows" \
        "reset-first should still run the same-month repeat-pass lookup"
    assert_contains "$calls" "$TEST_TENANT_ID" \
        "reset-first repeat-pass lookup should include the confirmed tenant"
    assert_not_contains "$calls" "$OTHER_TENANT_ID" \
        "reset-first repeat-pass lookup must not scan other allowlisted tenants"
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

test_reset_strips_materialized_tenant_allowlist_shell_escape() {
    setup_workspace "${TEST_TENANT_ID}\\"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=none"

    assert_eq "$RUN_EXIT_CODE" "0" "reset should accept a materialized allowlist tenant with a retained shell escape"
    local artifact_dir calls
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "materialized shell escape should not block reset completion"
    assert_contains "$calls" "SELECT stripe_customer_id FROM customers WHERE id = '$TEST_TENANT_ID' /* stage4_reset_customer_lookup */" \
        "reset customer lookup should use the canonical tenant UUID"
    assert_not_contains "$calls" "WHERE id = '${TEST_TENANT_ID}\\'" \
        "reset customer lookup must not preserve the materialized shell escape"
}

test_reset_lib_entrypoint_delegates_to_rehearsal_owner() {
    setup_workspace "$TEST_TENANT_ID"
    run_reset_helper_direct --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=none"

    assert_eq "$RUN_EXIT_CODE" "0" "reset helper lib entrypoint should delegate to the rehearsal owner"
    local artifact_dir calls
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "reset helper lib entrypoint should preserve the reset_completed contract"
    assert_contains "$calls" "stage4_reset_customer_lookup" \
        "reset helper lib entrypoint should execute reset orchestration through the existing owner"
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

test_reset_first_runs_allowlisted_reset_before_live_rehearsal() {
    setup_workspace "$TEST_TENANT_ID"
    wrap_preflight_owner_with_call_log
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-04 --reset-first --confirm-test-tenant $TEST_TENANT_ID --confirm-live-mutation" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=clearable_trio" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON={\"data\":[{\"id\":\"si_reset_draft\",\"status\":\"draft\"},{\"id\":\"si_reset_open\",\"status\":\"open\"},{\"id\":\"si_reset_uncollectible\",\"status\":\"uncollectible\"}]}"

    assert_eq "$RUN_EXIT_CODE" "0" "reset-first path should reset allowlisted test tenant before live rehearsal"

    local calls customer_lookup_line delete_line stripe_line dry_run_line health_line psql_line billing_line
    calls="$(cat "$TEST_CALL_LOG")"
    customer_lookup_line="$(first_call_line_matching '^psql|.*stage4_reset_customer_lookup')"
    delete_line="$(first_call_line_matching '^psql|.*stage4_reset_delete_invoices')"
    stripe_line="$(first_call_line_matching '^curl|.*https://api.stripe.com/v1/invoices')"
    dry_run_line="$(first_call_line_matching '^dry_run|')"
    health_line="$(first_call_line_matching '^curl|.*/health')"
    psql_line="$(first_call_line_matching '^psql|.*SELECT COUNT(\*) FROM usage_records')"
    billing_line="$(first_call_line_matching '^curl|.*/admin/billing/run')"

    assert_contains "$calls" "stage4_reset_customer_lookup" \
        "reset-first should use the existing reset customer lookup owner"
    assert_contains "$calls" "stage4_reset_invoice_rows" \
        "reset-first should use the existing reset invoice-row owner"
    assert_contains "$calls" "stage4_reset_delete_invoices" \
        "reset-first should use the existing reset DB cleanup owner"
    assert_contains "$calls" "curl| -sS -K" \
        "reset-first should use the existing Stripe HTTP transport"
    assert_not_contains "$calls" "reset_first_cleanup|" \
        "reset-first must not introduce an ad hoc cleanup command"

    if [ -n "$customer_lookup_line" ] && [ -n "$dry_run_line" ] && [ "$customer_lookup_line" -lt "$dry_run_line" ]; then
        pass "reset customer lookup should run before preflight dry run"
    else
        fail "reset customer lookup must run before dry run (lookup=${customer_lookup_line:-missing} dry_run=${dry_run_line:-missing})"
    fi
    if [ -n "$delete_line" ] && [ -n "$health_line" ] && [ "$delete_line" -lt "$health_line" ]; then
        pass "reset cleanup should run before health probe"
    else
        fail "reset cleanup must run before health probe (delete=${delete_line:-missing} health=${health_line:-missing})"
    fi
    if [ -n "$delete_line" ] && [ -n "$psql_line" ] && [ "$delete_line" -lt "$psql_line" ]; then
        pass "reset cleanup should run before metering evidence"
    else
        fail "reset cleanup must run before metering evidence (delete=${delete_line:-missing} metering=${psql_line:-missing})"
    fi
    if [ -n "$delete_line" ] && [ -n "$billing_line" ] && [ "$delete_line" -lt "$billing_line" ]; then
        pass "reset cleanup should run before billing mutation"
    else
        fail "reset cleanup must run before billing mutation (delete=${delete_line:-missing} billing=${billing_line:-missing})"
    fi
    if [ -n "$stripe_line" ] && [ -n "$dry_run_line" ] && [ "$stripe_line" -lt "$dry_run_line" ]; then
        pass "Stripe reset transport should run before preflight dry run"
    else
        fail "Stripe reset transport must run before dry run (stripe=${stripe_line:-missing} dry_run=${dry_run_line:-missing})"
    fi
}

test_reset_first_fails_closed_without_allowlisted_confirmed_tenant() {
    setup_workspace
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-04 --reset-first --confirm-test-tenant $TEST_TENANT_ID --confirm-live-mutation"

    assert_reset_blocked_with "test_tenant_allowlist_missing" \
        "reset-first path without FJCLOUD_TEST_TENANT_IDS"

    local calls
    calls="$(cat "$TEST_CALL_LOG")"
    assert_not_contains "$calls" "dry_run|" \
        "reset-first allowlist failure should not run preflight dry run"
    assert_not_contains "$calls" "/health" \
        "reset-first allowlist failure should not probe health"
    assert_not_contains "$calls" "/admin/billing/run" \
        "reset-first allowlist failure should not attempt live billing mutation"
}

test_reset_first_repeat_pass_is_limited_to_confirmed_tenant() {
    setup_workspace "$TEST_TENANT_ID,$OTHER_TENANT_ID"
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-04 --reset-first --confirm-test-tenant $TEST_TENANT_ID --confirm-live-mutation" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=none" \
        "REHEARSAL_MOCK_SAME_MONTH_LOOKUP_MODE=other_allowlisted_tenant"

    assert_eq "$RUN_EXIT_CODE" "0" "reset-first should ignore same-month invoices outside the confirmed tenant"
    local artifact_dir calls same_month_call
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"
    same_month_call="$(grep '^psql|.*stage3_existing_same_month_invoice_rows' "$TEST_CALL_LOG" | tail -1 || true)"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "rehearsal_completed" \
        "reset-first should run live mutation instead of reusing an unreset allowlisted tenant invoice"
    assert_contains "$same_month_call" "$TEST_TENANT_ID" \
        "same-month repeat lookup should include the confirmed reset tenant"
    assert_not_contains "$same_month_call" "$OTHER_TENANT_ID" \
        "same-month repeat lookup must not include unreset allowlisted tenants during reset-first"
    assert_contains "$calls" "/admin/billing/run" \
        "reset-first should proceed to billing mutation when only another allowlisted tenant has same-month evidence"
}

test_reset_uses_staging_db_query_owner_when_local_db_url_missing() {
    setup_workspace "$TEST_TENANT_ID"
    write_explicit_env_file_without_keys "$TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env" \
        DATABASE_URL \
        INTEGRATION_DB_URL
    printf 'FJCLOUD_TEST_TENANT_IDS=%s\n' "$TEST_TENANT_ID" >> "$TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env"

    local ssm_exec="$TEST_WORKSPACE/scripts/launch/mock_ssm_exec_staging.sh"
    cat > "$ssm_exec" <<MOCK
#!/usr/bin/env bash
echo "ssm_exec|\$*" >> "$TEST_CALL_LOG"
DATABASE_URL=postgres://remote-staging-db.example/fjcloud
export DATABASE_URL
PATH="$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin" bash -c "\$1"
MOCK
    chmod +x "$ssm_exec"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "STAGING_DB_QUERY_SCRIPT=$ssm_exec" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=none"

    assert_eq "$RUN_EXIT_CODE" "0" "reset should use staging DB query owner when the operator env has no local DB URL"
    local artifact_dir calls
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "SSM-backed reset should report reset_completed"
    assert_contains "$calls" "ssm_exec|" \
        "reset should delegate DB reads to the staging DB query owner"
    assert_contains "$calls" 'psql -tAq "$DATABASE_URL"' \
        "remote DB query should use the staging host DATABASE_URL"
    assert_contains "$calls" "stage4_reset_customer_lookup" \
        "SSM-backed reset should run the customer lookup query remotely"
}

test_live_rehearsal_uses_staging_db_query_owner_when_local_db_url_missing() {
    setup_workspace "$TEST_TENANT_ID"
    write_explicit_env_file_without_keys "$TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env" \
        DATABASE_URL INTEGRATION_DB_URL

    local ssm_exec="$TEST_WORKSPACE/scripts/launch/mock_ssm_exec_live.sh"
    cat > "$ssm_exec" <<MOCK
#!/usr/bin/env bash
echo "ssm_exec|\$*" >> "$TEST_CALL_LOG"
DATABASE_URL=postgres://remote-staging-db.example/fjcloud
export DATABASE_URL
PATH="$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin" bash -c "\$1"
MOCK
    chmod +x "$ssm_exec"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "STAGING_DB_QUERY_SCRIPT=$ssm_exec"

    assert_rehearsal_succeeds
    local artifact_dir calls
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"
    assert_eq "$(json_file_field "$artifact_dir/steps/metering_evidence.json" "classification")" "metering_evidence_ready" \
        "live path should satisfy metering through the staging DB query owner"
    assert_eq "$(json_file_field "$artifact_dir/steps/live_mutation_guard.json" "classification")" "live_mutation_guard_passed" \
        "live guard should accept the staging DB query owner as DB evidence access"
    assert_contains "$calls" "ssm_exec|" "live path should delegate no-local-DB evidence reads to SSM"
    assert_contains "$calls" "/admin/billing/run" "live path should still run the billing mutation"
}

test_live_rehearsal_hydrates_stale_admin_key_from_staging_ssm() {
    setup_workspace "$TEST_TENANT_ID"
    {
        grep -v '^ADMIN_KEY=' "$TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env"
        printf 'ADMIN_KEY=stale-operator-env-file-key\n'
    } > "$TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env.next"
    mv "$TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env.next" \
        "$TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation"

    assert_eq "$RUN_EXIT_CODE" "0" "live rehearsal should use canonical staging SSM admin key over stale env-file key"
    local calls
    calls="$(cat "$TEST_CALL_LOG")"
    assert_contains "$calls" "aws|ssm get-parameter" \
        "live rehearsal should hydrate staging runtime credentials through the existing SSM owner"
    assert_contains "$calls" "/admin/billing/run" \
        "live rehearsal should reach the authenticated billing mutation"
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
    assert_contains "$calls" "https://api.stripe.com/v1/invoices?customer=cus_reset_test&limit=100" \
        "reset should list stripe invoices for the target customer"
    assert_contains "$calls" "-X DELETE https://api.stripe.com/v1/invoices/si_reset_draft" \
        "draft stripe invoices should be deleted"
    assert_contains "$calls" "-X POST https://api.stripe.com/v1/invoices/si_reset_open/void" \
        "open stripe invoices should be voided"
    assert_contains "$calls" "-X POST https://api.stripe.com/v1/invoices/si_reset_uncollectible/void" \
        "uncollectible stripe invoices should be voided"
    assert_not_contains "$calls" "https://api.stripe.com/v1/invoices/si_reset_draft/void" \
        "draft stripe invoices must never hit the void path"

    db_delete_line="$(first_call_line_matching '^psql|.*stage4_reset_delete_invoices')"
    stripe_delete_line="$(first_call_line_matching '^curl|.*-X DELETE .*si_reset_draft')"
    stripe_void_line="$(first_call_line_matching '^curl|.*-X POST .*si_reset_open/void')"
    if [ -n "$db_delete_line" ] && [ -n "$stripe_delete_line" ] && [ -n "$stripe_void_line" ] && \
        [ "$db_delete_line" -gt "$stripe_delete_line" ] && [ "$db_delete_line" -gt "$stripe_void_line" ]; then
        pass "DB invoice deletion should happen after stripe cleanup succeeds"
    else
        fail "DB invoice deletion must run after stripe cleanup (delete=${stripe_delete_line:-missing} void=${stripe_void_line:-missing} db=${db_delete_line:-missing})"
    fi
}

test_reset_accepts_large_valid_stripe_list_json() {
    setup_workspace "$TEST_TENANT_ID"
    local large_list_file
    large_list_file="$TEST_WORKSPACE/tmp/large_stripe_invoice_list.json"
    python3 - "$large_list_file" <<'PY'
import json
import sys

items = [
    {"id": "si_reset_draft", "status": "draft"},
    {"id": "si_reset_open", "status": "open"},
    {"id": "si_reset_uncollectible", "status": "uncollectible"},
]
for index in range(6000):
    items.append({
        "id": f"in_padding_{index:05d}",
        "status": "paid",
        "description": "padding-" + ("x" * 80),
    })
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"object": "list", "data": items}, handle)
PY
    cat > "$TEST_WORKSPACE/bin/python3" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = "-" ] && [ "$#" -ge 2 ] && [ "${#2}" -gt 100000 ]; then
    echo "mock python3: Argument list too long" >&2
    exit 126
fi
exec /usr/bin/python3 "$@"
MOCK
    chmod +x "$TEST_WORKSPACE/bin/python3"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=clearable_trio" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON_FILE=$large_list_file"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "reset should accept large valid Stripe list JSON without argv-size parser failures"
    local artifact_dir calls
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "large valid Stripe list should complete reset cleanup"
    assert_contains "$calls" "-X DELETE https://api.stripe.com/v1/invoices/si_reset_draft" \
        "large list parsing should still find draft invoice status"
    assert_contains "$calls" "-X POST https://api.stripe.com/v1/invoices/si_reset_open/void" \
        "large list parsing should still find open invoice status"
    assert_contains "$calls" "-X POST https://api.stripe.com/v1/invoices/si_reset_uncollectible/void" \
        "large list parsing should still find uncollectible invoice status"
}

test_reset_stripe_list_invalid_json_reports_diagnostics() {
    setup_workspace "$TEST_TENANT_ID"
    local malformed_body
    malformed_body='{"data":[{"id":"si_reset_draft","status":"draft"}],"next":'

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_SSM_STRIPE_SECRET_KEY=abc" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=clearable_trio" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON=$malformed_body"

    assert_rehearsal_fails_as_blocker
    local artifact_dir summary_json summary_detail calls
    artifact_dir="$(artifact_dir_from_stdout)"
    summary_json="$(cat "$artifact_dir/summary.json")"
    summary_detail="$(json_file_field "$artifact_dir/summary.json" "detail")"
    calls="$(cat "$TEST_CALL_LOG")"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_stripe_list_invalid" \
        "invalid stripe list JSON should keep the stable reset_stripe_list_invalid classification"
    assert_contains "$summary_detail" "customer=cus_reset_test" \
        "invalid stripe list detail should include the target customer"
    assert_contains "$summary_detail" "http=200" \
        "invalid stripe list detail should include the Stripe HTTP code"
    assert_contains "$summary_detail" "api_base=https://api.stripe.com" \
        "invalid stripe list detail should include the effective Stripe API base"
    assert_contains "$summary_detail" "body_bytes=58" \
        "invalid stripe list detail should include the Stripe body byte count"
    assert_contains "$summary_detail" "body_preview={\"data\":[{\"id\":\"si_reset_draft\",\"status\":\"draft\"}],\"next\":" \
        "invalid stripe list detail should include a bounded Stripe body preview"
    assert_contains "$summary_detail" "key_fingerprint=unrecognized:*redacted_short_key" \
        "invalid stripe list detail should redact short effective key fingerprints"
    assert_not_contains "$summary_json" "abc" \
        "summary JSON must not include the raw short Stripe key"
    assert_not_contains "$RUN_STDOUT" "abc" \
        "stdout must not include the raw short Stripe key"
    assert_not_contains "$calls" "abc" \
        "call log must not include the raw short Stripe key"
    assert_not_contains "$summary_json" "sk_test_rehearsal_contract" \
        "summary JSON must not include the raw Stripe fixture secret"
    assert_not_contains "$RUN_STDOUT" "sk_test_rehearsal_contract" \
        "stdout must not include the raw Stripe fixture secret"
    assert_not_contains "$calls" "sk_test_rehearsal_contract" \
        "call log must not include the raw Stripe fixture secret"
    assert_not_contains "$summary_json" "Authorization" \
        "summary JSON must not include Authorization"
    assert_not_contains "$RUN_STDOUT" "Authorization" \
        "stdout must not include Authorization"
    assert_not_contains "$calls" "Authorization" \
        "call log must not include Authorization"
}

test_reset_uses_stripe_http_api_when_cli_missing() {
    setup_workspace "$TEST_TENANT_ID"
    rm -f "$TEST_WORKSPACE/bin/stripe"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=clearable_trio" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON={\"data\":[{\"id\":\"si_reset_draft\",\"status\":\"draft\"},{\"id\":\"si_reset_open\",\"status\":\"open\"},{\"id\":\"si_reset_uncollectible\",\"status\":\"uncollectible\"}]}"

    assert_eq "$RUN_EXIT_CODE" "0" "reset should not require the stripe CLI on the staging host"
    local artifact_dir calls
    artifact_dir="$(artifact_dir_from_stdout)"
    calls="$(cat "$TEST_CALL_LOG")"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "reset_completed" \
        "missing stripe CLI should not block reset completion"
    assert_contains "$calls" "curl| -sS -K" \
        "reset should use the shared Stripe HTTP transport"
    assert_contains "$calls" "curl| -sS -K - -D" \
        "reset should stream credentials through the shared curl config transport"
    assert_contains "$calls" "https://api.stripe.com/v1/invoices?customer=cus_reset_test&limit=100" \
        "reset should list invoices through Stripe HTTP API"
    assert_contains "$calls" "https://api.stripe.com/v1/invoices/si_reset_draft" \
        "reset should delete draft invoices through Stripe HTTP API"
    assert_contains "$calls" "https://api.stripe.com/v1/invoices/si_reset_open/void" \
        "reset should void open invoices through Stripe HTTP API"
    assert_not_contains "$calls" "stripe|" \
        "reset should not shell out to the stripe CLI"
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
    assert_not_contains "$calls" "https://api.stripe.com/v1/invoices/si_reset_paid/void" \
        "paid stripe invoices must never hit the void path"
    assert_not_contains "$calls" "-X DELETE https://api.stripe.com/v1/invoices/si_reset_paid" \
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
    assert_not_contains "$calls" "/void" \
        "missing stripe IDs should not trigger stripe void calls"
    assert_not_contains "$calls" "-X DELETE https://api.stripe.com/v1/invoices/" \
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
    assert_not_contains "$calls" "/void" \
        "missing stripe IDs should not trigger stripe void calls"
    assert_not_contains "$calls" "-X DELETE https://api.stripe.com/v1/invoices/" \
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
    first_delete_count="$(grep -c '^curl|.*-X DELETE .*https://api.stripe.com/v1/invoices/' "$TEST_CALL_LOG" || true)"
    first_void_count="$(grep -c '^curl|.*-X POST .*https://api.stripe.com/v1/invoices/.*/void' "$TEST_CALL_LOG" || true)"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --reset-test-state --confirm-test-tenant $TEST_TENANT_ID" \
        "REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE=clearable_trio" \
        "REHEARSAL_MOCK_STRIPE_LIST_JSON={\"data\":[{\"id\":\"si_reset_draft\",\"status\":\"draft\"},{\"id\":\"si_reset_open\",\"status\":\"open\"},{\"id\":\"si_reset_uncollectible\",\"status\":\"uncollectible\"}]}"
    assert_eq "$RUN_EXIT_CODE" "0" "second reset invocation should succeed as a no-op"

    local second_artifact_dir second_delete_count second_void_count
    second_artifact_dir="$(artifact_dir_from_stdout)"
    second_delete_count="$(grep -c '^curl|.*-X DELETE .*https://api.stripe.com/v1/invoices/' "$TEST_CALL_LOG" || true)"
    second_void_count="$(grep -c '^curl|.*-X POST .*https://api.stripe.com/v1/invoices/.*/void' "$TEST_CALL_LOG" || true)"

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
test_reset_first_runs_reset_before_live_rehearsal
test_reset_first_limits_repeat_pass_lookup_to_confirmed_tenant
test_reset_rejects_missing_allowlist
test_reset_rejects_non_allowlisted_tenant
test_reset_allowlisted_tenant_reaches_reset_orchestration
test_reset_strips_materialized_tenant_allowlist_shell_escape
test_reset_lib_entrypoint_delegates_to_rehearsal_owner
test_reset_accepts_explicit_month_without_live_mutation_confirmation
test_reset_first_runs_allowlisted_reset_before_live_rehearsal
test_reset_first_fails_closed_without_allowlisted_confirmed_tenant
test_reset_first_repeat_pass_is_limited_to_confirmed_tenant
test_reset_uses_staging_db_query_owner_when_local_db_url_missing
test_live_rehearsal_uses_staging_db_query_owner_when_local_db_url_missing
test_live_rehearsal_hydrates_stale_admin_key_from_staging_ssm
test_reset_status_aware_stripe_cleanup_and_db_delete_order
test_reset_accepts_large_valid_stripe_list_json
test_reset_stripe_list_invalid_json_reports_diagnostics
test_reset_uses_stripe_http_api_when_cli_missing
test_reset_paid_invoice_deletes_db_rows_without_voiding_paid
test_reset_paid_invoice_without_stripe_id_uses_db_only_cleanup
test_reset_draft_invoice_without_stripe_id_uses_db_only_cleanup
test_reset_db_delete_only_cleared_stripe_invoice_rows
test_reset_second_invocation_is_clean_noop
test_reset_completed_summary_only_on_full_success
run_test_summary
