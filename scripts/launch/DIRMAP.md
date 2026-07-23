<!-- [scrai:start] -->
## launch

| File | Summary |
| --- | --- |
| apply_ses_log_read_policy.sh | apply_ses_log_read_policy.sh — guarded rollout of the least-privilege SES
send-events CloudWatch Logs read policy onto the staging fjcloud instance role.

WHY A GUARDED CLI (not a bare `terraform apply`)
------------------------------------------------
The policy shape is owned, and only owned, by Terraform at
ops/iam/fjcloud-instance-role.tf (resource fjcloud_ses_send_events_read). |
| capture_billing_cross_check_inputs.sh | capture_billing_cross_check_inputs.sh — read-only Stage 1 billing replay bundle capture. |
| capture_stage_d_evidence.sh | capture_stage_d_evidence.sh — end-to-end Blocker-3 live evidence
capture, owner-script style.

Sequencing (each step gates the next):
  1) Verify the deployed staging API picks up the tenant-map URL
     fallback (i.e. |
| hydrate_seeder_env_from_ssm.sh | hydrate_seeder_env_from_ssm.sh — print KEY=VALUE lines that satisfy the
execute-contract env vars consumed by staging-targeted tooling.

Despite the historical "seeder" name (kept for path stability), this is the
canonical SSM hydrator for staging tooling subshells. |
| live_stripe_reverify.sh | Orchestrate live Stripe re-verification from owner summary through refund/readback.
shellcheck disable=SC1091. |
| multi_tenant_isolation_probe.sh | thin multi-tenant isolation probe wrapper over seed_synthetic_traffic owners. |
| post_deploy_verify_tenant_map.sh | post_deploy_verify_tenant_map.sh — confirm the deployed staging API
picks up the tenant-map URL fallback from infra/api/src/routes/internal.rs.

Usage:
  bash scripts/launch/post_deploy_verify_tenant_map.sh

Pre-conditions:
  - .secret/.env.secret already sourced (AWS creds present)
  - hydrate_seeder_env_from_ssm.sh has set ADMIN_KEY / API_URL etc.

Output: prints the deployed flapjack_url for tenant A and exits 0 if
non-null, exits 1 otherwise. |
| post_wave_a_sync_prod.sh | post_wave_a_sync_prod.sh — Wrap the dev→prod debbie sync + CI wait +
deploy-verify dance into a single invocation.

Usage:
  bash scripts/launch/post_wave_a_sync_prod.sh --check-only
  bash scripts/launch/post_wave_a_sync_prod.sh --execute [--yes] \
      --expected-dev-sha <40hex> --expected-staging-pages-sha <40hex> \
      --receipt <absolute-new-json>
  bash scripts/launch/post_wave_a_sync_prod.sh --help

Modes:
  --check-only  Read-only drift check: probes prod /version via
                deploy_status.sh --json and prints the prod drift
                envelope (dev_sha, build_time age, commits_behind_main).
                No mutations — safe to call from local-ci.sh.

  --execute     Promote current dev main to prod: verify the staging
                mirror has validated exactly this content (staging was
                synced from the current dev HEAD SHA per debbie's sync
                manifest, AND staging CI is green at the staging mirror
                HEAD — including the post-deploy e2e-deployed job prod CI
                does not run), then run debbie sync prod, poll mirror CI
                until green or timeout, and verify the deploy landed via
                the post_wave_sync_to_prod_verify_test. |
| privacy_card_sweeper.sh | Close stale lane-scoped Privacy.com cards and emit deterministic summary JSON.
shellcheck disable=SC1091. |
| run_browser_lane_against_staging.sh | run_browser_lane_against_staging.sh — drive the LB-2 / LB-3 Playwright
specs against deployed staging on current-main code and capture an
evidence bundle.

┌─ READ THIS BEFORE ITERATING ─────────────────────────────────────────────┐
│ This is the FINAL GATE, not the debug loop. |
| run_browser_lane_locally.sh | run_browser_lane_locally.sh — FAST local iteration lane for the LB-2 / LB-3
Stripe billing browser specs.

─── Why this exists ──────────────────────────────────────────────────────
scripts/launch/run_browser_lane_against_staging.sh drives the SAME two specs
but only against DEPLOYED staging, so every code change costs a 30–60 min
deploy round-trip. |
| run_full_backend_validation.sh | shellcheck disable=SC1091,SC2004,SC2016. |
| run_ses_coverage_a1_in_vpc.sh | run_ses_coverage_a1_in_vpc.sh — canonical §1 six-probe in-VPC coverage runner.

Packages the repo at --sha via `git archive`, hydrates the sole SSM-online
staging instance, and runs the six §1 SES-coverage probe owners THROUGH
scripts/launch/ssm_exec_staging.sh (the reuse seam — no new SSM code here).
It then generates the evidence bundle (per-probe sidecars, probe_results.tsv,
all_green.txt, failure_classifications.json) and the canonical
run_manifest.json + run_status.json using the imported detection logic in
scripts/lib/ses_coverage_a1_integrity.py (the single canonical owner).

Exit taxonomy (spec-fixed; only 0/10 authorize downstream classification):
    0  green             — all six probes green
    10 complete_red      — clean run, §1 red (per-probe detail in the manifest)
    20 setup_failed      — `git archive` packaging failure
    21 structural_failed — host hydration / SSM offline / checkout / emit failure
    22 cleanup_failed    — S3 / remote-temp cleanup trap failure

This runner makes no live customer claim and performs no external mutation of
customer state; its live execution against real Stripe/SES/CloudWatch/S3 is
Wave 3's job. |
| seed_synthetic_traffic.sh | seed_synthetic_traffic.sh — populate staging `usage_records` with
representative tenant traffic so the billing-rehearsal lane can produce
real invoices across all three customer archetypes.

Status: SKELETON. |
| ssm_exec_staging.sh | ssm_exec_staging.sh — synchronously run a shell command on the staging
fjcloud API EC2 instance via AWS SSM RunShellScript.

Usage:
  scripts/launch/ssm_exec_staging.sh "<shell command...>"

Returns the SSM invocation's StandardOutputContent on stdout and exits
with the command's status. |
| validate_debbie_dry_run.py | Validate a captured Debbie staging dry run against its TOML sync scope.

This owner validates only Debbie's advertised top-level scope and exclusions.
Debbie remains responsible for directory enumeration and exclude matching. |
| validate_launch_closeout.py | Fail-closed anti-drift validator for the Wave 3 launch closeout receipt. |
| verify_e2e_deployed_gate.sh | Stub summary for scripts/launch/verify_e2e_deployed_gate.sh. |
| wait_for_pages_parity.sh | wait_for_pages_parity.sh — Poll served Cloudflare Pages bytes until
PAGES_ALIAS_URL/_app/version.json reports the target git SHA, then mark
`ready=true` for the GitHub Actions step output.
On timeout, mark `ready=false`, emit an error, and exit non-zero so stale
deployed Pages content fails before browser evidence is trusted.

This script is the single owner of the parity poll. |
| wave3_phase_receipt.py | Wave 3 phase receipt writer/validator.

Receipts are cleanup-safe resume pointers only. |
<!-- [scrai:end] -->
