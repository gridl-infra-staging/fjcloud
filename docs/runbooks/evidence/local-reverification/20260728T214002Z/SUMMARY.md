# Section 2 Local Reverification

tested_head_sha=b7dddead4a367682bf16cf4de37bdaf686af4d99
tested_head_log=b7dddead4 matt: stage 2 completion
bundle_path=docs/runbooks/evidence/local-reverification/20260728T214002Z
section2_matrix_rows_total=11
section2: rows_total=14 rows_run_locally=13 rows_green=13 rows_red=0 rows_not_local=1

## Stripe Amount Proof
- "actual_amount_paid_cents=500 expected_amount_paid_cents=500"

## Module Filters
stripe_webhook_signature_test matched 5 tests:
- stripe_webhook_signature_test::local_stripe_service_rejects_invalid_signature_with_bad_request
- stripe_webhook_signature_test::missing_signature_header_returns_bad_request
- stripe_webhook_signature_test::mock_stripe_service_accepts_any_signature_value
- stripe_webhook_signature_test::valid_signature_accepts_deprecated_subscription_event
- stripe_webhook_signature_test::valid_signature_processes_event

stripe_webhook_idempotency_test matched 8 tests:
- stripe_webhook_idempotency_test::concurrent_duplicate_invoice_event_loser_stays_out_of_handler
- stripe_webhook_idempotency_test::replayed_checkout_completed_event_is_noop_once
- stripe_webhook_idempotency_test::replayed_invoice_event_is_processed_once
- stripe_webhook_idempotency_test::replayed_subscription_event_is_noop_once
- stripe_webhook_idempotency_test::resume_before_pause_waiter_exists_does_not_deadlock_mark_paid
- stripe_webhook_idempotency_test::resume_waits_for_pause_handshake_internally
- stripe_webhook_idempotency_test::retry_after_first_handler_failure_stays_unprocessed_and_not_acknowledged
- stripe_webhook_idempotency_test::seeded_unprocessed_invoice_event_short_circuits_without_handler_side_effects

## Relationship Results
- stripe_test_clock_full_cycle_amount: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_stripe_test_clock_full_cycle.log
- integration_stripe_payment_failure_webhook: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_integration_stripe_payment_failure.log
- stripe_webhook_signature_module: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_stripe_webhook_signature.log
- stripe_webhook_idempotency_module: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_stripe_webhook_idempotency.log
- stripe_webhook_charge_refunded_event_matrix: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_stripe_webhook_event_matrix_charge_refunded.log
- billing_upgrade_requires_action_rollback: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_billing_upgrade_requires_action.log
- stripe_pay_invoice_requires_action_contract: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_stripe_pay_invoice_requires_action.log
- legacy_subscription_routes_404: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_legacy_subscription_routes.log
- metering_rollup_next_day_boundary: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_metering_rollup_next_day_boundary.db_env.log
- billing_smoke_pg_usage_repo_read_path: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_billing_smoke_pg_usage_repo_read_path.db_env.log
- region_multiplier_hot_storage: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_region_multiplier_hot_storage.log
- multi_region_storage_attachment: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_multi_region_storage_attachment.log
- compute_invoice_rate_override: status=green exit_code=0 log=docs/runbooks/evidence/local-reverification/20260728T214002Z/raw/section2_compute_invoice_rate_override.log

## Operator-Only Residual
- row_label=stripe_dashboard_operator_only_residual owner_path=docs/runbooks/paid_beta_rc_signoff.md status=not_local residual_reason=Stripe Dashboard operator-only paid beta signoff is not locally executable.

## Raw Log Inventory
- raw/bundle_guard.py
- raw/closing_git_status_and_diff.log
- raw/db_local_dev_reachability_probe.log
- raw/db_precondition_probe.log
- raw/preflight_stripe_env_probe.log
- raw/reachability_billing_list.log
- raw/reachability_platform_list.log
- raw/relationship_results.json
- raw/secret_material_scan.log
- raw/secret_material_scan.py
- raw/secret_pattern_scan.log
- raw/section2_billing_smoke_pg_usage_repo_read_path.db_env.log
- raw/section2_billing_smoke_pg_usage_repo_read_path.log
- raw/section2_billing_smoke_pg_usage_repo_read_path.rerun2.log
- raw/section2_billing_upgrade_requires_action.log
- raw/section2_compute_invoice_rate_override.log
- raw/section2_integration_stripe_payment_failure.log
- raw/section2_legacy_subscription_routes.log
- raw/section2_metering_rollup_next_day_boundary.db_env.log
- raw/section2_metering_rollup_next_day_boundary.log
- raw/section2_metering_rollup_next_day_boundary.rerun2.log
- raw/section2_multi_region_storage_attachment.log
- raw/section2_region_multiplier_hot_storage.log
- raw/section2_stripe_pay_invoice_requires_action.log
- raw/section2_stripe_test_clock_full_cycle.log
- raw/section2_stripe_webhook_event_matrix_charge_refunded.log
- raw/section2_stripe_webhook_idempotency.log
- raw/section2_stripe_webhook_signature.log
- bundle_validation.log

## Environment Notes
- Stripe preflight printed only prefix/presence markers in raw/preflight_stripe_env_probe.log.
- Two DB-backed metering commands first failed the live gate with Database unreachable; raw/db_precondition_probe.log and raw/db_local_dev_reachability_probe.log diagnose the missing ambient DB env and reachable loopback local-dev Postgres. Final green reruns are raw/section2_metering_rollup_next_day_boundary.db_env.log and raw/section2_billing_smoke_pg_usage_repo_read_path.db_env.log.
- The first example secret grep matched a non-secret test identifier in raw/reachability_billing_list.log. raw/secret_material_scan.log is the final redacted material scan and passed with no secret material.
- Closing status in raw/closing_git_status_and_diff.log shows the only uncommitted Stage 3 repo change is this new bundle. The origin/main diff also lists pre-existing lane files from earlier stages: chats/icg/jul28_11am_4_matrix_billing_reverification.md and infra/api/tests/integration/stripe_test_clock_full_cycle_test.rs.
