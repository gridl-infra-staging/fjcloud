# Stage 1 staging currency summary

- classification: `parity_converged`
- ready: `true`
- target_dev_sha: `c106025d6761b51d05d0b624e2c10aeba9589c8e`
- staging_dev_sha_post_convergence: `c106025d6761b51d05d0b624e2c10aeba9589c8e`
- staging_mirror_sha_post_convergence: `0b069a56a9e73e97b1b9859a8676f938535777d1`
- staging_commits_behind_main_post_convergence: `0`
- staging_deployable_drift_post_convergence: `false`
- served_pages_version: `0b069a56a9e73e97b1b9859a8676f938535777d1`
- newest_live_state_bundle: `docs/live-state/20260712T024627Z`
- pricing_cta: `pass`
- no_browser_lane_claims_made: `true`

Stage 1 initially preserved a bounded Pages parity mismatch because the checklist command waited for the dev repo SHA while the deployed Pages bundle was stamped with the staging mirror SHA. The canonical staging mirror run later completed successfully: `staging_run_29177317821_final_jobs.txt` records `deploy-staging=success` and `e2e-deployed=success`, and `deploy_status_post_convergence.json` records staging `dev_sha` at the target SHA, `commits_behind_main=0`, `deployable_drift=false`, and mirror SHA matching the served Pages version.

Lane 5 decision: not rerun; no product-side flip recorded on `origin/main`. The canonical Lane 5 record is `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/SUMMARY.md`; it records `all_green.txt=0`, Section 1 remains partial, and the existing Stage 2 RC expectation remains the pre-authorized `NOT-READY-on-section-1` shape unless later evidence changes it.

Key evidence:
- `parity_lock_and_ci.txt`
- `probe_live_state.stdout.txt`
- `probe_live_state.stderr.txt`
- `debbie_sync_staging.stdout.txt`
- `debbie_sync_staging.stderr.txt`
- `staging_mirror_after_sync.txt`
- `staging_run_29177317821_jobs.txt`
- `staging_run_29177317821_final_jobs.txt`
- `deploy_status_final.json`
- `deploy_status_post_convergence.json`
- `deploy_status_post_convergence.stderr.txt`
- `deploy_status_post_convergence.exitcode`
- `pages_parity.stderr.txt`
- `pages_parity.github_output.txt`
- `pricing.http_status`
- `pricing_probe_result.txt`
- `pages_version_body.json`
- `pages_parity_mirror_diagnostic.stderr.txt`
