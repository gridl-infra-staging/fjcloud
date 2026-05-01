<!-- [scrai:start] -->
## launch

| File | Summary |
| --- | --- |
| capture_billing_cross_check_inputs.sh | Stub summary for capture_billing_cross_check_inputs.sh. |
| capture_stage_d_evidence.sh | capture_stage_d_evidence.sh — end-to-end Blocker-3 live evidence
capture, owner-script style.

Sequencing (each step gates the next):
  1) Verify the deployed staging API picks up the tenant-map URL
     fallback (i.e. |
| hydrate_seeder_env_from_ssm.sh | hydrate_seeder_env_from_ssm.sh — print KEY=VALUE lines that satisfy the
execute-contract env vars consumed by scripts/launch/seed_synthetic_traffic.sh.

Resolves canonical SSM-owned values for the staging environment so an
operator can do:

  set -a; source .secret/.env.secret; set +a   # AWS credentials
  eval "$(scripts/launch/hydrate_seeder_env_from_ssm.sh staging)"
  bash scripts/launch/seed_synthetic_traffic.sh \
    --tenant A --execute --i-know-this-hits-staging --duration-minutes 60

This script ONLY produces the four required variables that come from SSM
or are derived from SSM-owned values; FLAPJACK_API_KEY is intentionally
NOT exported, because the seeder now resolves the per-node key per
flapjack_url at call time (see node_api_key_for_url() in seed_synthetic_traffic.sh). |
| post_deploy_evidence_capture.sh | Stub summary for post_deploy_evidence_capture.sh. |
| post_deploy_verify_tenant_map.sh | post_deploy_verify_tenant_map.sh — confirm the deployed staging API
picks up the tenant-map URL fallback from infra/api/src/routes/internal.rs.

Usage:
  bash scripts/launch/post_deploy_verify_tenant_map.sh

Pre-conditions:
  - .secret/.env.secret already sourced (AWS creds present)
  - hydrate_seeder_env_from_ssm.sh has set ADMIN_KEY / API_URL etc.

Output: prints the deployed flapjack_url for tenant A and exits 0 if
non-null, exits 1 otherwise. |
| run_full_backend_validation.sh | Stub summary for run_full_backend_validation.sh. |
| seed_synthetic_traffic.sh | Stub summary for seed_synthetic_traffic.sh. |
| ssm_exec_staging.sh | ssm_exec_staging.sh — synchronously run a shell command on the staging
fjcloud API EC2 instance via AWS SSM RunShellScript.

Usage:
  scripts/launch/ssm_exec_staging.sh "<shell command...>"

Returns the SSM invocation's StandardOutputContent on stdout and exits
with the command's status. |
<!-- [scrai:end] -->
