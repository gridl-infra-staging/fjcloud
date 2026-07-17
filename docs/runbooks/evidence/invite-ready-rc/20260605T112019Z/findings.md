# Invite-Ready RC Findings

## Verdict

- Verdict: `NOT-READY`.
- Coordinator summary: `mode=paid_beta_rc`, `ready=false`, `verdict=fail`, `timestamp=2026-06-05T11:24:10Z`.
- Classification source: `LAUNCH.md ## Shippable endpoints` allows `LAUNCH-READY`, pre-authorized `NOT-READY-on-section-1`, per-run `NOT-READY-on-section-5`, and otherwise plain `NOT-READY`.
- Matrix source: `docs/launch_verification_matrix.md:29-41` currently marks Section 1 partial and Sections 2-6 live/eligible; `docs/launch_verification_matrix.md:221-223` points full backend validation at `scripts/launch/run_full_backend_validation.sh`.
- This run is plain `NOT-READY` because the saved RC summary has failing/gap statuses outside the sole Section 1 partial shape and outside a sole Section 5 residual shape.
- The `browser_signup_paid` and `browser_portal_cancel` `critical_surface_skipped` failures are interpreted using the accepted precedent in `LAUNCH.md:458-462`; they are not a new waiver path, and they do not make this run shippable because other real failures/gaps are present.

## Evidence Bundle

- Bundle: `docs/runbooks/evidence/invite-ready-rc/20260605T112019Z`.
- Primary machine-readable result: `docs/runbooks/evidence/invite-ready-rc/20260605T112019Z/summary.json`, written by `emit_final_result`.
- RC summary used for classification: `docs/runbooks/evidence/invite-ready-rc/20260605T112019Z/rc_summary.json`, copied from the harness-owned bundle summary because no post-dispatch `launch-rc-runs` summary existed.
- Harness PID and exit: `49061` / `1`.

## Status Counts

- `external_secret_missing`: 3
- `fail`: 3
- `live_evidence_gap`: 3
- `pass`: 12
- `skip`: 1

## Blocking Steps

- `cargo_workspace_tests`: `fail` / `cargo test --workspace failed` -> follow-up `chats/icg/wave3_cargo_workspace_tests.md`.
- `backend_launch_gate`: `external_secret_missing` / `backend_launch_gate_commerce_local_env_missing` -> follow-up `chats/icg/wave3_backend_launch_gate.md`.
- `local_signoff`: `external_secret_missing` / `local_signoff_prerequisites_unsatisfied` -> follow-up `chats/icg/wave3_local_signoff.md`.
- `staging_billing_rehearsal`: `live_evidence_gap` / `credentialed_billing_month_missing` -> follow-up `chats/icg/wave3_staging_billing_rehearsal.md`.
- `browser_auth_setup`: `external_secret_missing` / `browser_auth_setup_env_gap` -> follow-up `chats/icg/wave3_browser_auth_setup.md`.
- `staging_runtime_smoke`: `live_evidence_gap` / `credentialed_staging_smoke_inputs_missing` -> follow-up `chats/icg/wave3_staging_runtime_smoke.md`.
- `test_clock`: `live_evidence_gap` / `stripe_test_clock_full_cycle_owner_requires_live_mode` -> follow-up `chats/icg/wave3_test_clock.md`.
- `browser_signup_paid`: `fail` / `critical_surface_skipped` -> follow-up `chats/icg/wave3_browser_signup_paid.md`.
- `browser_portal_cancel`: `fail` / `critical_surface_skipped` -> follow-up `chats/icg/wave3_browser_portal_cancel.md`.

## Non-Pass Evidence Items

- `cargo_workspace_tests`: `fail` / `cargo test --workspace failed`.
- `backend_launch_gate`: `external_secret_missing` / `backend_launch_gate_commerce_local_env_missing`.
- `local_signoff`: `external_secret_missing` / `local_signoff_prerequisites_unsatisfied`.
- `staging_billing_rehearsal`: `live_evidence_gap` / `credentialed_billing_month_missing`.
- `browser_auth_setup`: `external_secret_missing` / `browser_auth_setup_env_gap`.
- `staging_runtime_smoke`: `live_evidence_gap` / `credentialed_staging_smoke_inputs_missing`.
- `canary_customer_loop`: `skip` / `probe_env_gap_aws_inbox_env_missing`.
- `test_clock`: `live_evidence_gap` / `stripe_test_clock_full_cycle_owner_requires_live_mode`.
- `browser_signup_paid`: `fail` / `critical_surface_skipped`.
- `browser_portal_cancel`: `fail` / `critical_surface_skipped`.

## Concrete Log Evidence

- `cargo_workspace_tests.log` records two failing integration tests: `indexes_test::create_index_reuses_existing_shared_vm_when_load_snapshot_is_missing` expected `https://shared-unscraped.flapjack.foo/1/indexes` but got `http://localhost:10918/1/indexes`; `indexes_test::create_index_zero_resource_fallback_prefers_vm_with_load_telemetry` expected `https://vm-alive.flapjack.foo/1/indexes` but got `http://localhost:10918/1/indexes`.
- `rc_harness_stdout.log` records backend live-gate precondition failures for `stripe_listen_not_running` and missing DB URL, then the final JSON summary with `ready=false`.

## Next-Stage Disposition

- Stage 5 must not proceed from this RC result.
- The lane still needs Stage 6 batch closeout to record this terminal verdict and the follow-up contract before stopping.
- Required follow-up checklist inputs should start from the listed `chats/icg/wave3_<failing_step>.md` paths for each blocking step; the shared-VM routing regression must be fixed before rerunning this RC gate.

## Open Questions

- Which prior change caused shared-VM index create requests to route through `LOCAL_DEV_FLAPJACK_URL` instead of the selected VM `flapjack_url`?
- Are `INTEGRATION_DB_URL`/`DATABASE_URL`, Stripe listen forwarding, and browser auth env inputs expected to be supplied by this lane before the next RC run, or should their owner scripts reclassify any missing inputs more specifically?
- Should the `canary_customer_loop` `skip` status remain non-blocking for this verdict shape, given the emitted reason `probe_env_gap_aws_inbox_env_missing`?
