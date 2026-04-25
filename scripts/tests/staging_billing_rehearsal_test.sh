#!/usr/bin/env bash
# Red-first contract tests for scripts/staging_billing_rehearsal.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/staging_billing_rehearsal_harness.sh
source "$SCRIPT_DIR/lib/staging_billing_rehearsal_harness.sh"

test_requires_explicit_env_file_flag() {
    setup_workspace
    run_rehearsal --args "--month 2026-03 --confirm-live-mutation"

    assert_rehearsal_fails_as_blocker
    assert_valid_json "$RUN_STDOUT" "missing --env-file output should be valid JSON"
    assert_contains "$RUN_STDOUT" "--env-file" "missing --env-file failure should name required flag"
    assert_contains "$RUN_STDOUT" "explicit_env_file_required" "missing --env-file should emit explicit env-file blocker"

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "explicit_env_file_required" \
        "missing --env-file blocker should be recorded in summary classification"
}

test_rejects_repo_default_env_filename() {
    setup_workspace
    run_rehearsal --args "--env-file .env.local --month 2026-03 --confirm-live-mutation"

    assert_rehearsal_fails_as_blocker
    assert_valid_json "$RUN_STDOUT" "repo-default env filename output should be valid JSON"
    assert_contains "$RUN_STDOUT" ".env.local" "repo-default env filename rejection should name the path"
    assert_contains "$RUN_STDOUT" "repo_default_env_file_rejected" "repo-default env filename should emit stable blocker classification"

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "repo_default_env_file_rejected" \
        "repo-default env filename blocker should be recorded in summary classification"
}

test_rejects_nonexistent_explicit_env_file() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    local missing_env_file="$TEST_WORKSPACE/inputs/staging_rehearsal.missing.env"
    run_rehearsal --args "--env-file $missing_env_file --month 2026-03 --confirm-live-mutation"

    assert_rehearsal_fails_as_blocker
    assert_valid_json "$RUN_STDOUT" "nonexistent explicit env-file output should be valid JSON"
    assert_contains "$RUN_STDOUT" "explicit_env_file_missing" \
        "nonexistent explicit env-file should emit stable blocker classification"
    assert_contains "$RUN_STDOUT" "$missing_env_file" \
        "nonexistent explicit env-file blocker should name the missing path"

    local artifact_dir calls
    artifact_dir="$(find_artifact_dir)"
    calls="$(cat "$TEST_CALL_LOG")"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "explicit_env_file_missing" \
        "nonexistent explicit env-file blocker should be recorded in summary classification"
    assert_not_contains "$calls" "dry_run|" \
        "nonexistent explicit env-file should block before preflight owner invocation"
    assert_not_contains "$calls" "psql|" \
        "nonexistent explicit env-file should block before metering evidence queries"
    assert_not_contains "$calls" "curl|" \
        "nonexistent explicit env-file should block before health probes"
}

test_requires_month_when_live_mutation_confirmation_present() {
    setup_workspace
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --confirm-live-mutation"

    assert_eq "$RUN_EXIT_CODE" "1" "--confirm-live-mutation without --month should fail"
    assert_valid_json "$RUN_STDOUT" "missing --month output should be valid JSON"
    assert_contains "$RUN_STDOUT" "--month" "missing --month failure should name required flag"
    assert_contains "$RUN_STDOUT" "billing_month_required" "missing --month should emit stable blocker classification"
}

test_requires_confirm_live_mutation_when_month_provided() {
    setup_workspace
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03"

    assert_eq "$RUN_EXIT_CODE" "1" "--month without --confirm-live-mutation should fail"
    assert_valid_json "$RUN_STDOUT" "missing --confirm-live-mutation output should be valid JSON"
    assert_contains "$RUN_STDOUT" "--confirm-live-mutation" "missing confirmation failure should name required flag"
    assert_contains "$RUN_STDOUT" "live_mutation_confirmation_required" "missing confirmation should emit stable blocker classification"
}

test_preflight_runs_before_metering_and_mutation_paths() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation"

    assert_rehearsal_succeeds

    local dry_run_line dry_run_entry psql_line health_line billing_line
    dry_run_line="$(first_call_line_matching '^dry_run|')"
    psql_line="$(first_call_line_matching '^psql|')"
    health_line="$(first_call_line_matching '^curl|.*/health')"
    billing_line="$(first_call_line_matching '^curl|.*/admin/billing/run')"

    if [ -n "$dry_run_line" ]; then
        dry_run_entry="$(sed -n "${dry_run_line}p" "$TEST_CALL_LOG")"
        assert_contains "$dry_run_entry" "--check" "preflight owner invocation should include --check"
        pass "preflight owner should run in configured rehearsal flow"
    else
        fail "configured rehearsal must call staging_billing_dry_run.sh --check before later stages"
    fi

    if [ -n "$dry_run_line" ] && [ -n "$psql_line" ] && [ "$dry_run_line" -lt "$psql_line" ]; then
        pass "preflight owner runs before metering evidence queries"
    else
        fail "configured rehearsal must run metering evidence after preflight (dry_run=${dry_run_line:-?} psql=${psql_line:-missing})"
    fi

    if [ -n "$health_line" ] && [ -n "$billing_line" ] && [ "$health_line" -lt "$billing_line" ]; then
        pass "health probe runs before live billing call"
    else
        fail "live billing call must run after health probe (health=${health_line:-missing} billing=${billing_line:-missing})"
    fi

    if [ -n "$psql_line" ] && [ -n "$billing_line" ] && [ "$psql_line" -lt "$billing_line" ]; then
        pass "live billing call runs after metering evidence queries"
    else
        fail "live billing call must run after metering evidence (psql=${psql_line:-missing} billing=${billing_line:-missing})"
    fi

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_summary_and_step_files_exist "$artifact_dir"
    assert_health_step_exists "$artifact_dir"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "result")" "passed" \
        "configured rehearsal should report passed when live evidence converges"
    assert_eq "$(json_file_field "$artifact_dir/steps/live_mutation_guard.json" "result")" "passed" \
        "live mutation guard should pass before live attempt"
    assert_eq "$(json_file_field "$artifact_dir/steps/live_mutation_attempt.json" "result")" "passed" \
        "live mutation attempt should pass when evidence converges"
    assert_contains "$(read_file_or_empty "$artifact_dir/billing_run.json")" "\"inv_stage3_a\"" \
        "billing_run artifact should record created invoice IDs"
    assert_contains "$(read_file_or_empty "$artifact_dir/billing_run.json")" "\"inv_stage3_b\"" \
        "billing_run artifact should record every created invoice ID"
}

test_live_mutation_fails_when_batch_response_has_no_created_invoices() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_BATCH_MODE=no_created"

    assert_rehearsal_fails_as_blocker

    local artifact_dir summary_payload
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"

    summary_payload="$(read_file_or_empty "$artifact_dir/summary.json")"
    assert_valid_json "$summary_payload" "batch no-created summary should be valid JSON"
    assert_eq "$(json_field "$summary_payload" "classification")" "billing_run_no_created_invoices" \
        "no-created batch response should fail closed with stable classification"
    assert_eq "$(json_file_field "$artifact_dir/billing_run.json" "classification")" "billing_run_no_created_invoices" \
        "billing_run artifact should preserve no-created classification"
}

test_live_mutation_fails_when_billing_request_times_out() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_BILLING_CURL_EXIT=124"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "billing_run_request_timed_out" \
        "billing run timeout should emit timeout-specific classification"
    assert_eq "$(json_file_field "$artifact_dir/billing_run.json" "classification")" "billing_run_request_timed_out" \
        "billing_run artifact should preserve timeout-specific classification"
}

test_live_mutation_fails_when_billing_request_times_out_with_native_curl_exit_28() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_BILLING_CURL_EXIT=28"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "billing_run_request_timed_out" \
        "native curl timeout exit should emit timeout-specific billing classification"
    assert_eq "$(json_file_field "$artifact_dir/billing_run.json" "classification")" "billing_run_request_timed_out" \
        "billing_run artifact should preserve timeout-specific classification for native curl timeouts"
}

test_live_mutation_fails_when_invoice_rows_never_converge() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_INVOICE_READY_AFTER=99" \
        "REHEARSAL_EVIDENCE_MAX_ATTEMPTS=3" \
        "REHEARSAL_EVIDENCE_SLEEP_SEC=0"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "invoice_rows_not_ready" \
        "invoice evidence timeout should fail closed"
    assert_eq "$(json_file_field "$artifact_dir/invoice_rows.json" "classification")" "invoice_rows_not_ready" \
        "invoice_rows artifact should preserve timeout classification"
}

test_live_mutation_fails_when_invoice_rows_query_times_out() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_INVOICE_QUERY_EXIT=124"

    assert_rehearsal_fails_as_blocker

    local artifact_dir summary_detail invoice_rows_detail
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "invoice_rows_query_failed" \
        "invoice_rows query timeout should preserve query-failed classification family"
    summary_detail="$(json_file_field "$artifact_dir/summary.json" "detail")"
    assert_contains "$summary_detail" "timed out" \
        "invoice_rows timeout detail should explicitly report timeout"
    invoice_rows_detail="$(json_file_field "$artifact_dir/invoice_rows.json" "detail")"
    assert_contains "$invoice_rows_detail" "timed out" \
        "invoice_rows artifact detail should preserve timeout-specific detail"
}

test_live_mutation_fails_when_invoice_rows_query_hits_statement_timeout() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_INVOICE_QUERY_EXIT=1" \
        "REHEARSAL_MOCK_INVOICE_QUERY_STDERR=ERROR: canceling statement due to statement timeout"

    assert_rehearsal_fails_as_blocker

    local artifact_dir summary_detail invoice_rows_detail
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "invoice_rows_query_failed" \
        "statement timeout should keep invoice_rows query-failed classification family"
    summary_detail="$(json_file_field "$artifact_dir/summary.json" "detail")"
    assert_contains "$summary_detail" "timed out" \
        "statement timeout should be reported as timed out in summary detail"
    invoice_rows_detail="$(json_file_field "$artifact_dir/invoice_rows.json" "detail")"
    assert_contains "$invoice_rows_detail" "timed out" \
        "statement timeout should be reported as timed out in invoice_rows artifact detail"
}

test_live_mutation_fails_when_invoice_rows_missing_required_fields() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_INVOICE_MODE=missing_paid_at" \
        "REHEARSAL_EVIDENCE_MAX_ATTEMPTS=3" \
        "REHEARSAL_EVIDENCE_SLEEP_SEC=0"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "invoice_rows_missing_required_fields" \
        "missing invoice fields should fail closed"
    assert_eq "$(json_file_field "$artifact_dir/invoice_rows.json" "classification")" "invoice_rows_missing_required_fields" \
        "invoice_rows artifact should preserve missing-field classification"
}

test_live_mutation_fails_when_webhook_query_times_out() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_WEBHOOK_QUERY_EXIT=124"

    assert_rehearsal_fails_as_blocker

    local artifact_dir summary_detail webhook_detail
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "webhook_query_failed" \
        "webhook query timeout should preserve query-failed classification family"
    summary_detail="$(json_file_field "$artifact_dir/summary.json" "detail")"
    assert_contains "$summary_detail" "timed out" \
        "webhook timeout detail should explicitly report timeout"
    webhook_detail="$(json_file_field "$artifact_dir/webhook.json" "detail")"
    assert_contains "$webhook_detail" "timed out" \
        "webhook artifact detail should preserve timeout-specific detail"
}

test_live_mutation_fails_when_webhook_rows_never_converge() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_WEBHOOK_READY_AFTER=99" \
        "REHEARSAL_EVIDENCE_MAX_ATTEMPTS=3" \
        "REHEARSAL_EVIDENCE_SLEEP_SEC=0"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "webhook_not_ready" \
        "webhook evidence timeout should fail closed"
    assert_eq "$(json_file_field "$artifact_dir/webhook.json" "classification")" "webhook_not_ready" \
        "webhook artifact should preserve timeout classification"
}

test_live_mutation_fails_when_webhook_rows_unprocessed() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_WEBHOOK_MODE=unprocessed" \
        "REHEARSAL_EVIDENCE_MAX_ATTEMPTS=3" \
        "REHEARSAL_EVIDENCE_SLEEP_SEC=0"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "webhook_not_processed" \
        "missing processed invoice.payment_succeeded rows should fail closed"
    assert_eq "$(json_file_field "$artifact_dir/webhook.json" "classification")" "webhook_not_processed" \
        "webhook artifact should preserve unprocessed classification"
}

test_live_mutation_fails_when_email_runtime_is_unsupported() {
    setup_workspace
    wrap_preflight_owner_with_call_log
    write_explicit_env_file_without_keys "$TEST_WORKSPACE/inputs/staging_rehearsal.no_mailpit.env" "MAILPIT_API_URL"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.no_mailpit.env --month 2026-03 --confirm-live-mutation"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "invoice_email_evidence_delegated" \
        "missing runtime email observability should emit delegated staging classification"
    assert_eq "$(json_file_field "$artifact_dir/invoice_email.json" "classification")" "invoice_email_evidence_delegated" \
        "invoice_email artifact should preserve delegated staging classification"
}

test_blocker_path_keeps_json_summary_and_blocked_step_artifacts() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "result")" "blocked" \
        "blocker summary should report result=blocked"
    assert_contains "$(read_file_or_empty "$artifact_dir/steps/live_mutation_attempt.json")" "blocked" \
        "unattempted live-mutation step should emit blocker artifact instead of disappearing"
    assert_no_live_mutation_attempt_logged
}

test_failure_path_keeps_json_summary_and_blocked_later_step_artifacts() {
    setup_workspace
    write_explicit_env_file_without_keys "$TEST_WORKSPACE/inputs/staging_rehearsal.no_stripe.env" "STRIPE_SECRET_KEY"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.no_stripe.env --month 2026-03 --confirm-live-mutation"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "result")" "failed" \
        "failure summary should report result=failed"
    assert_contains "$(read_file_or_empty "$artifact_dir/steps/preflight.json")" "stripe_secret_key_missing" \
        "preflight failure artifact should preserve dry-run classification style"
    assert_health_step_absent "$artifact_dir"
    assert_contains "$(read_file_or_empty "$artifact_dir/steps/live_mutation_attempt.json")" "blocked" \
        "later live-mutation step should still emit blocker artifact"
    assert_no_live_mutation_attempt_logged
}

test_malformed_env_file_still_emits_blocker_artifacts() {
    setup_workspace

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.malformed.env --month 2026-03 --confirm-live-mutation"

    assert_rehearsal_fails_as_blocker
    assert_valid_json "$RUN_STDOUT" "malformed env-file output should be valid JSON"
    assert_contains "$RUN_STDOUT" "env_file_parse_failed" \
        "malformed env-file blocker should emit env_file_parse_failed classification"

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "env_file_parse_failed" \
        "malformed env-file blocker should be recorded in summary classification"
}

test_refuses_live_mutation_without_admin_key() {
    setup_workspace
    write_explicit_env_file_without_keys "$TEST_WORKSPACE/inputs/staging_rehearsal.no_admin.env" "ADMIN_KEY"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.no_admin.env --month 2026-03 --confirm-live-mutation"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "admin_key_missing" \
        "missing ADMIN_KEY in the explicit env file should emit stable blocker classification"
    assert_contains "$(read_file_or_empty "$artifact_dir/steps/live_mutation_attempt.json")" "blocked" \
        "missing ADMIN_KEY should leave live-mutation attempt as blocked artifact"
    assert_no_live_mutation_attempt_logged
}

test_refuses_live_mutation_without_db_evidence_access() {
    setup_workspace
    write_explicit_env_file_without_keys "$TEST_WORKSPACE/inputs/staging_rehearsal.no_db.env" \
        "DATABASE_URL" \
        "INTEGRATION_DB_URL"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.no_db.env --month 2026-03 --confirm-live-mutation"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "db_url_missing" \
        "missing DATABASE_URL and INTEGRATION_DB_URL in the explicit env file should emit stable blocker classification"
    assert_contains "$(read_file_or_empty "$artifact_dir/steps/live_mutation_attempt.json")" "blocked" \
        "missing DB evidence access should leave live-mutation attempt as blocked artifact"
    assert_no_live_mutation_attempt_logged
}

test_accepts_database_url_without_integration_db_url() {
    setup_workspace
    wrap_preflight_owner_with_call_log
    write_explicit_env_file_without_keys "$TEST_WORKSPACE/inputs/staging_rehearsal.database_only.env" "INTEGRATION_DB_URL"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.database_only.env --month 2026-03 --confirm-live-mutation"

    assert_eq "$RUN_EXIT_CODE" "0" "DATABASE_URL-only flow should complete live mutation successfully"

    local artifact_dir classification psql_line
    artifact_dir="$(find_artifact_dir)"
    classification="$(json_file_field "$artifact_dir/summary.json" "classification")"
    if [ "$classification" != "db_url_missing" ]; then
        pass "DATABASE_URL alone should avoid db_url_missing classification"
    else
        fail "DATABASE_URL alone must satisfy DB evidence precondition"
    fi

    psql_line="$(grep -n '^psql|' "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
    if [ -n "$psql_line" ]; then
        pass "DATABASE_URL-only flow should attempt metering evidence queries"
    else
        fail "DATABASE_URL-only flow should still invoke metering evidence owner"
    fi
    assert_contains "$(cat "$TEST_CALL_LOG")" "/admin/billing/run" \
        "DATABASE_URL-only flow should allow live mutation call"
}

test_accepts_integration_db_url_without_database_url() {
    setup_workspace
    wrap_preflight_owner_with_call_log
    write_explicit_env_file_without_keys "$TEST_WORKSPACE/inputs/staging_rehearsal.integration_db_only.env" "DATABASE_URL"

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.integration_db_only.env --month 2026-03 --confirm-live-mutation"

    assert_eq "$RUN_EXIT_CODE" "0" "INTEGRATION_DB_URL-only flow should complete live mutation successfully"

    local artifact_dir classification psql_line
    artifact_dir="$(find_artifact_dir)"
    classification="$(json_file_field "$artifact_dir/summary.json" "classification")"
    if [ "$classification" != "db_url_missing" ]; then
        pass "INTEGRATION_DB_URL alone should avoid db_url_missing classification"
    else
        fail "INTEGRATION_DB_URL alone must satisfy DB evidence precondition"
    fi

    psql_line="$(grep -n '^psql|' "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
    if [ -n "$psql_line" ]; then
        pass "INTEGRATION_DB_URL-only flow should attempt metering evidence queries"
    else
        fail "INTEGRATION_DB_URL-only flow should still invoke metering evidence owner"
    fi
    assert_contains "$(cat "$TEST_CALL_LOG")" "/admin/billing/run" \
        "INTEGRATION_DB_URL-only flow should allow live mutation call"
}

test_refuses_live_mutation_without_month() {
    assert_refusal_matrix_case \
        "missing --month" \
        "billing_month_required" \
        "--confirm-live-mutation"
}

test_refuses_live_mutation_without_confirmation_flag() {
    assert_refusal_matrix_case \
        "missing --confirm-live-mutation" \
        "live_mutation_confirmation_required" \
        "--month 2026-03"
}

test_live_mutation_fails_when_mailpit_messages_missing_created_invoice_ids() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_MAILPIT_MODE=generic_without_invoice_ids" \
        "REHEARSAL_EVIDENCE_MAX_ATTEMPTS=3" \
        "REHEARSAL_EVIDENCE_SLEEP_SEC=0"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "invoice_email_not_ready" \
        "generic stale Mailpit messages must not satisfy invoice-specific evidence"
    assert_eq "$(json_file_field "$artifact_dir/invoice_email.json" "classification")" "invoice_email_not_ready" \
        "invoice_email artifact should capture missing invoice-ID evidence as not ready"
    assert_contains "$(read_file_or_empty "$artifact_dir/invoice_email.json")" "inv_stage3_a" \
        "invoice_email artifact should record missing created invoice IDs"
}

test_live_mutation_fails_when_mailpit_search_returns_invalid_json() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_MAILPIT_MODE=invalid_search_json"

    assert_rehearsal_fails_as_blocker

    local artifact_dir summary_detail
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "invoice_email_query_failed" \
        "invalid Mailpit search JSON should fail closed as terminal query failure"
    assert_eq "$(json_file_field "$artifact_dir/invoice_email.json" "classification")" "invoice_email_query_failed" \
        "invoice_email artifact should preserve terminal query-failed classification for invalid search JSON"
    summary_detail="$(json_file_field "$artifact_dir/summary.json" "detail")"
    assert_contains "$summary_detail" "invalid JSON" \
        "invalid Mailpit search JSON should be called out explicitly in failure detail"
}

test_live_mutation_fails_when_mailpit_message_fetch_returns_invalid_json() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_MAILPIT_MODE=invalid_message_json"

    assert_rehearsal_fails_as_blocker

    local artifact_dir summary_detail
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "invoice_email_query_failed" \
        "invalid Mailpit message JSON should fail closed as terminal query failure"
    assert_eq "$(json_file_field "$artifact_dir/invoice_email.json" "classification")" "invoice_email_query_failed" \
        "invoice_email artifact should preserve terminal query-failed classification for invalid message JSON"
    summary_detail="$(json_file_field "$artifact_dir/summary.json" "detail")"
    assert_contains "$summary_detail" "invalid JSON" \
        "invalid Mailpit message JSON should be called out explicitly in failure detail"
}

test_live_mutation_fetches_full_mailpit_message_payload_for_invoice_id_correlation() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_MAILPIT_MODE=summary_without_invoice_ids_body_has_invoice_id"

    assert_rehearsal_succeeds

    local artifact_dir message_call
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "rehearsal_completed" \
        "full-message invoice-id correlation should allow successful live evidence closure"
    assert_eq "$(json_file_field "$artifact_dir/invoice_email.json" "classification")" "invoice_email_ready" \
        "invoice_email artifact should report ready when full message body includes created invoice IDs"

    message_call="$(grep '^curl|.*api/v1/message/msg-inv_stage3_a' "$TEST_CALL_LOG" | head -1 || true)"
    assert_contains "$message_call" "/api/v1/message/msg-inv_stage3_a" \
        "runner should fetch full Mailpit message payload for invoice-id correlation"
}

test_live_mutation_fails_when_mailpit_query_times_out() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_MAILPIT_CURL_EXIT=124"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "invoice_email_query_timed_out" \
        "mailpit timeout should emit timeout-specific classification"
    assert_eq "$(json_file_field "$artifact_dir/invoice_email.json" "classification")" "invoice_email_query_timed_out" \
        "invoice_email artifact should preserve timeout-specific classification"
}

test_live_mutation_fails_when_mailpit_query_times_out_with_native_curl_exit_28() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_MAILPIT_CURL_EXIT=28"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "invoice_email_query_timed_out" \
        "native curl timeout exit should emit timeout-specific mailpit classification"
    assert_eq "$(json_file_field "$artifact_dir/invoice_email.json" "classification")" "invoice_email_query_timed_out" \
        "invoice_email artifact should preserve timeout-specific classification for native curl timeouts"
}

test_live_mutation_uses_bounded_http_timeouts_for_health_billing_and_mailpit() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_HTTP_TIMEOUT_SEC=7"

    assert_rehearsal_succeeds

    local health_line billing_line mailpit_line
    health_line="$(first_call_line_matching '^curl|.*/health')"
    billing_line="$(first_call_line_matching '^curl|.*/admin/billing/run')"
    mailpit_line="$(first_call_line_matching '^curl|.*/api/v1/search')"

    local health_call billing_call mailpit_call
    health_call="$(sed -n "${health_line}p" "$TEST_CALL_LOG" 2>/dev/null || true)"
    billing_call="$(sed -n "${billing_line}p" "$TEST_CALL_LOG" 2>/dev/null || true)"
    mailpit_call="$(sed -n "${mailpit_line}p" "$TEST_CALL_LOG" 2>/dev/null || true)"

    assert_contains "$health_call" "--connect-timeout 7" \
        "health probe should set curl connect timeout"
    assert_contains "$health_call" "--max-time 7" \
        "health probe should set curl max-time"

    assert_contains "$billing_call" "--connect-timeout 7" \
        "billing mutation call should set curl connect timeout"
    assert_contains "$billing_call" "--max-time 7" \
        "billing mutation call should set curl max-time"

    assert_contains "$mailpit_call" "--connect-timeout 7" \
        "mailpit search call should set curl connect timeout"
    assert_contains "$mailpit_call" "--max-time 7" \
        "mailpit search call should set curl max-time"
}

test_live_mutation_urlencodes_mailpit_query_for_plus_alias_emails() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_INVOICE_MODE=plus_alias_email"

    assert_rehearsal_succeeds

    local mailpit_call
    mailpit_call="$(grep '^curl|.*api/v1/search' "$TEST_CALL_LOG" | head -1 || true)"
    assert_contains "$mailpit_call" "query=to%3Aalpha%2Balerts%40example.test%20subject%3Ainvoice" \
        "mailpit query must URL-encode plus-address search expressions"
    assert_not_contains "$mailpit_call" "query=to:alpha+alerts@example.test+subject:invoice" \
        "mailpit query must not send raw query text with unescaped + characters"
}

test_rehearsal_live_evidence_shell_files_stay_under_hard_limits() {
    local impl_file test_file harness_file run_live_file run_live_fn_lines
    local write_mock_curl_fn_lines email_evidence_file email_evidence_fn_lines
    impl_file="$REPO_ROOT/scripts/lib/staging_billing_rehearsal_impl.sh"
    test_file="$REPO_ROOT/scripts/tests/staging_billing_rehearsal_test.sh"
    harness_file="$REPO_ROOT/scripts/tests/lib/staging_billing_rehearsal_harness.sh"
    run_live_file="$(rehearsal_function_file "run_live_mutation_attempt")"
    run_live_fn_lines=""
    if [ -n "$run_live_file" ]; then
        run_live_fn_lines="$(function_line_count "$run_live_file" "run_live_mutation_attempt")"
    fi
    write_mock_curl_fn_lines="$(function_line_count "$harness_file" "write_mock_curl")"
    email_evidence_file="$(rehearsal_function_file "check_invoice_email_evidence_once")"
    email_evidence_fn_lines=""
    if [ -n "$email_evidence_file" ]; then
        email_evidence_fn_lines="$(function_line_count "$email_evidence_file" "check_invoice_email_evidence_once")"
    fi

    assert_line_count_lte "$(script_line_count "$impl_file")" "800" \
        "staging_billing_rehearsal_impl.sh should stay at or below the 800-line hard limit"
    assert_line_count_lte "$(script_line_count "$test_file")" "800" \
        "staging_billing_rehearsal_test.sh should stay at or below the 800-line hard limit"
    assert_line_count_lte "$run_live_fn_lines" "100" \
        "run_live_mutation_attempt should stay at or below the 100-line hard limit"
    assert_line_count_lte "$email_evidence_fn_lines" "100" \
        "check_invoice_email_evidence_once should stay at or below the 100-line hard limit"
    assert_line_count_lte "$write_mock_curl_fn_lines" "100" \
        "write_mock_curl should stay at or below the 100-line hard limit"
}

test_rehearsal_runner_stays_under_repo_warning_thresholds() {
    local runner_path evidence_path file_line_count evidence_line_count
    local parse_args_line_count main_line_count
    runner_path="$REPO_ROOT/scripts/staging_billing_rehearsal.sh"
    evidence_path="$REPO_ROOT/scripts/lib/staging_billing_rehearsal_evidence.sh"
    file_line_count="$(script_line_count "$runner_path")"
    evidence_line_count="$(script_line_count "$evidence_path")"
    parse_args_line_count="$(function_line_count "$runner_path" "parse_args")"
    main_line_count="$(function_line_count "$runner_path" "main")"

    assert_line_count_lte "$file_line_count" "500" \
        "rehearsal runner should stay at or below the 500-line warning threshold"
    assert_line_count_lte "$evidence_line_count" "500" \
        "staging_billing_rehearsal_evidence.sh should stay at or below the 500-line warning threshold"
    assert_line_count_lte "$parse_args_line_count" "60" \
        "parse_args should stay at or below the 60-line warning threshold"
    assert_line_count_lte "$main_line_count" "60" \
        "main should stay at or below the 60-line warning threshold"
}

echo "=== staging_billing_rehearsal.sh contract tests (Stage 3 live evidence suite) ==="
test_requires_explicit_env_file_flag
test_rejects_repo_default_env_filename
test_rejects_nonexistent_explicit_env_file
test_requires_month_when_live_mutation_confirmation_present
test_requires_confirm_live_mutation_when_month_provided
test_preflight_runs_before_metering_and_mutation_paths
test_live_mutation_redacts_admin_key_and_locks_artifact_permissions
test_live_mutation_fails_when_batch_response_has_no_created_invoices
test_live_mutation_fails_when_billing_request_times_out
test_live_mutation_fails_when_billing_request_times_out_with_native_curl_exit_28
test_live_mutation_fails_when_invoice_rows_never_converge
test_live_mutation_fails_when_invoice_rows_query_times_out
test_live_mutation_fails_when_invoice_rows_query_hits_statement_timeout
test_live_mutation_fails_when_invoice_rows_missing_required_fields
test_live_mutation_fails_when_webhook_query_times_out
test_live_mutation_fails_when_webhook_rows_never_converge
test_live_mutation_fails_when_webhook_rows_unprocessed
test_live_mutation_fails_when_email_runtime_is_unsupported
test_blocker_path_keeps_json_summary_and_blocked_step_artifacts
test_failure_path_keeps_json_summary_and_blocked_later_step_artifacts
test_malformed_env_file_still_emits_blocker_artifacts
test_refuses_live_mutation_without_admin_key
test_refuses_live_mutation_without_db_evidence_access
test_accepts_database_url_without_integration_db_url
test_accepts_integration_db_url_without_database_url
test_refuses_live_mutation_without_month
test_refuses_live_mutation_without_confirmation_flag
test_live_mutation_fails_when_mailpit_messages_missing_created_invoice_ids
test_live_mutation_fails_when_mailpit_search_returns_invalid_json
test_live_mutation_fails_when_mailpit_message_fetch_returns_invalid_json
test_live_mutation_fetches_full_mailpit_message_payload_for_invoice_id_correlation
test_live_mutation_fails_when_mailpit_query_times_out
test_live_mutation_fails_when_mailpit_query_times_out_with_native_curl_exit_28
test_live_mutation_uses_bounded_http_timeouts_for_health_billing_and_mailpit
test_live_mutation_urlencodes_mailpit_query_for_plus_alias_emails
test_rehearsal_live_evidence_shell_files_stay_under_hard_limits
test_rehearsal_runner_stays_under_repo_warning_thresholds
run_test_summary
