# Accepted-SHA deploy gate: red before deployment

The first deployed-gate run for accepted dev SHA
`11737bafecc8def4174c3f6bbfaa9ee0f7e166da` reached a terminal failure on
GitHub Actions run `30068760960`, mirror SHA
`16731241d6f6b927ef2ec66e3df26e4ed47a913e`.

The mirror manifest matched the accepted dev SHA. Eight upstream jobs passed,
but `rust-test` failed, so `deploy-staging` and `e2e-deployed` were skipped.
No staging deployment occurred.

The sole failure was
`auth_endpoints_test::verification_with_valid_token_marks_verified`:
`infra/api/tests/integration/auth_endpoints_test.rs:972` required HTTP 201 but
the mock-pool route returned HTTP 500. Commit `9d9bf9044` on `origin/main`
replaced the prior admission-gate assertion with that full-creation assertion.
The immediately preceding implementation documented that this mock uses a
lazy pool bound to port 1 and therefore cannot exercise the DB-backed index
lifecycle lease. The failure is deterministic in the accepted code and is not
caused by the metering rollup repair or by Debbie.

The exact gate receipt is under `deployed_gate_attempt_01/`. Full bounded job
output and commit-history proof are in
`command_outputs/023_deploy_gate_failure_diagnosis.txt`.

Stage 1 remains open at the deployed gate. The accepted SHA must not be
reported as deployed until this repository-owned CI prerequisite is corrected
on `origin/main`, a new accepted SHA is frozen and synced, and the same gate
passes.
