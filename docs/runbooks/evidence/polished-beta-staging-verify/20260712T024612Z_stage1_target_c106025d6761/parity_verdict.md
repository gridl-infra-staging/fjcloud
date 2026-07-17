# Stage 1 parity verdict

- classification: `parity_converged`
- ready: `true`
- target_dev_sha: `c106025d6761b51d05d0b624e2c10aeba9589c8e`
- staging_dev_sha_post_convergence: `c106025d6761b51d05d0b624e2c10aeba9589c8e`
- staging_mirror_sha_post_convergence: `0b069a56a9e73e97b1b9859a8676f938535777d1`
- pages_parity_files: `pages_parity.stderr.txt`, `pages_parity.github_output.txt`, `pages_version_body.json`, `pages_parity_mirror_diagnostic.stderr.txt`
- pricing_cta_proof: `pricing.http_status`, `pricing_probe_result.txt`
- run_scoped_stub: `chats/icg/stubs/20260712_stage1_pages_target_mismatch_gap.md`

The canonical deploy path was used: `debbie sync staging` wrote staging mirror commit `0b069a56a9e73e97b1b9859a8676f938535777d1` with `.debbie/sync_manifest.json` pointing at dev SHA `c106025d6761b51d05d0b624e2c10aeba9589c8e`. The staging mirror `deploy-staging` job for `0b069a56a9e73e97b1b9859a8676f938535777d1` completed successfully.

API currency converged: `deploy_status_post_convergence.json` reports staging `dev_sha=c106025d6761b51d05d0b624e2c10aeba9589c8e`, mirror SHA `0b069a56a9e73e97b1b9859a8676f938535777d1`, `commits_behind_main=0`, and `deployable_drift=false`.

Pages satisfied the deployed mirror target after convergence. The original bounded Stage 1 command did not satisfy the checklist assertion as written because `pages_parity.stderr.txt` shows the served value and Cloudflare metadata both at mirror SHA `0b069a56a9e73e97b1b9859a8676f938535777d1`, while the command waited for dev SHA `c106025d6761b51d05d0b624e2c10aeba9589c8e`. The later canonical CI completion plus `deploy_status_post_convergence.json` establish that mirror SHA as the deployed staging mirror for the target dev SHA.

Pricing passed: `pricing.http_status` is `200`, and `pricing_probe_result.txt` records `pricing_cta=pass`.

Lane 5 was inspected on `origin/main`. The newest canonical in-VPC rerun summary is `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/SUMMARY.md`; it records `all_green.txt=0`, so the two Section 1 clickthrough probes were not rerun for Stage 1 and the Stage 2 RC expectation remains the pre-authorized `NOT-READY-on-section-1` shape.

No browser-lane or RC-readiness claims were made.
