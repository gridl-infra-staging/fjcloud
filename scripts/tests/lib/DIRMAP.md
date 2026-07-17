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
| invoke_rc_with_env_harness.sh | Shared harness helpers for invoke_rc_with_env shell tests.

Callers must define:
  REPO_ROOT
  TARGET_SCRIPT. |
| invoke_rc_with_env_readiness_cases.sh | Readiness taxonomy cases sourced by invoke_rc_with_env_test.sh. |
| live_e2e_budget_guardrail_prep_harness.sh | Shared harness helpers for live_e2e_budget_guardrail_prep contract tests. |
| local_dev_test_state.sh | Shared helpers for local-dev shell tests that temporarily replace repo-local state. |
| mock_cargo.sh | Shared test helper for mocking cargo invocations in gate script tests. |
| ses_coverage_a1_runner_harness.sh | Shared hermetic harness for scripts/launch/run_ses_coverage_a1_in_vpc.sh.

Callers define:
  REPO_ROOT, RUNNER, TEST_WORKSPACE, CLEANUP_DIRS. |
| staging_billing_rehearsal_harness.sh | Shared harness helpers for staging_billing_rehearsal shell tests.
shellcheck source=staging_billing_rehearsal_reset_harness_blocks.sh. |
<!-- [scrai:end] -->
