<!-- [scrai:start] -->
## lib

| File | Summary |
| --- | --- |
| assertions.sh | Shared assertions for shell test scripts.

Callers must define:
  pass "<message>"
  fail "<message>". |
| chaos_test_helpers.sh | Chaos-specific test helpers for chaos_test.sh.

Callers must define REPO_ROOT before sourcing.
Shared mock writer helper (write_mock_script) is sourced from test_helpers.sh. |
| integration_up_mocks.sh | Mock helpers for integration_up_test.sh.

Callers must define REPO_ROOT before sourcing.
Shared helpers (write_mock_script, backup/restore_repo_env_file) come from
test_helpers.sh — callers should source that first. |
| live_e2e_budget_guardrail_prep_harness.sh | Shared harness helpers for live_e2e_budget_guardrail_prep contract tests. |
| local_dev_test_state.sh | Stub summary for local_dev_test_state.sh. |
| mock_cargo.sh | Shared test helper for mocking cargo invocations in gate script tests. |
| seed_local_mocks.sh | Stub summary for seed_local_mocks.sh. |
| staging_billing_rehearsal_harness.sh | Stub summary for staging_billing_rehearsal_harness.sh. |
| staging_billing_rehearsal_reset_harness_blocks.sh | Stub summary for staging_billing_rehearsal_reset_harness_blocks.sh. |
<!-- [scrai:end] -->
