<!-- [scrai:start] -->
## launch

| File | Summary |
| --- | --- |
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
| multi_tenant_isolation_probe.sh | Stub summary for multi_tenant_isolation_probe.sh. |
| post_deploy_verify_tenant_map.sh | post_deploy_verify_tenant_map.sh — confirm the deployed staging API
picks up the tenant-map URL fallback from infra/api/src/routes/internal.rs.

Usage:
  bash scripts/launch/post_deploy_verify_tenant_map.sh

Pre-conditions:
  - .secret/.env.secret already sourced (AWS creds present)
  - hydrate_seeder_env_from_ssm.sh has set ADMIN_KEY / API_URL etc.

Output: prints the deployed flapjack_url for tenant A and exits 0 if
non-null, exits 1 otherwise. |
| privacy_card_sweeper.sh | Close stale lane-scoped Privacy.com cards and emit deterministic summary JSON.
shellcheck disable=SC1091. |
| run_browser_lane_against_staging.sh | run_browser_lane_against_staging.sh — drive the LB-2 / LB-3 Playwright
specs against deployed staging on current-main code and capture an
evidence bundle.

Closes the LB-2 (signup_to_paid_invoice) and LB-3
(billing_portal_payment_method_update) launch blockers per LAUNCH.md.
The browser navigates the deployed staging UI (cloud.staging.flapjack.foo).
Fixtures hit the deployed staging API (api.staging.flapjack.foo) with admin
credentials sourced from SSM. |
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
<!-- [scrai:end] -->
