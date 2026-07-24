# Stage 1 command log

Every command below records a UTC start time, exit code, and bounded combined
stdout/stderr artifact. Secret-bearing environment files are never copied or
printed.

| ID | UTC start | Exit | Command | Bounded stdout/stderr |
| --- | --- | ---: | --- | --- |
| 001 | 2026-07-24T04:49:53Z | 1 | Initial zsh logging-wrapper attempt around `git fetch origin` (wrapper failed after fetch on reserved variable `status`) | Session transport only; superseded by 001b |
| 001b | 2026-07-24T04:50:10Z | 0 | `git fetch origin` | `command_outputs/001b_git_fetch_origin.txt` |
| 002 | 2026-07-24T04:50:11Z | 0 | `git merge-base --is-ancestor fa7fc6a26 origin/main` | `command_outputs/002_rollup_repair_ancestry.txt` |
| 003 | 2026-07-24T04:50:11Z | 0 | Banked-artifact `git ls-tree` proof on `origin/main` | `command_outputs/003_banked_artifact_tree.txt` |
| 004 | 2026-07-24T04:50:11Z | 0 | `origin/main` live-state registration `git show \| rg` proof | `command_outputs/004_live_state_registration.txt` |
| 005 | 2026-07-24T04:50:11Z | 0 | `origin/main` local-CI registration `git show \| rg` proof | `command_outputs/005_local_ci_registration.txt` |
| 006 | 2026-07-24T04:50:11Z | 0 | Capture local HEAD, `origin/main`, and worktree status | `command_outputs/006_input_shas.txt` |
| 007 | 2026-07-24T04:51:07Z | 0 | Load the canonical external secret environment in a clean shell and run `aws sts get-caller-identity --output json` | `command_outputs/007_aws_caller_identity.txt` |
| 008 | 2026-07-24T04:53:15Z | 0 | `bash scripts/local-ci.sh --gate usage-rollup-freshness-contract` | `command_outputs/008_usage_rollup_freshness_contract.txt` |
| 009 | 2026-07-24T04:57:38Z | 0 | Run the credentialed predeploy `bash scripts/probe_live_state.sh` | `command_outputs/009_probe_live_state_predeploy.txt` |
| 010 | 2026-07-24T05:00:59Z | 0 | Copy the predeploy live-state summary/raw JSON and render the staging row | `command_outputs/010_predeploy_live_state_row.txt` |
| 011 | 2026-07-24T05:01:59Z | 0 | Query staging `usage_daily` and `usage_records` through `scripts/launch/ssm_exec_staging.sh` | `command_outputs/011_predeploy_usage_sql.txt` |
| 012 | 2026-07-24T05:02:02Z | 0 | Capture aggregation service/timer and API-host metering service status plus timer schedule over SSM | `command_outputs/012_predeploy_systemd_status.txt` |
| 013 | 2026-07-24T05:02:04Z | 0 | Capture seven-day aggregation-service journal over SSM | `command_outputs/013_predeploy_aggregation_journal.txt` |
| 014 | 2026-07-24T05:02:07Z | 0 | Capture seven-day aggregation-timer journal over SSM | `command_outputs/014_predeploy_timer_journal.txt` |
| 015 | 2026-07-24T05:02:09Z | 0 | Capture seven-day API-host metering-service journal over SSM | `command_outputs/015_predeploy_metering_journal.txt` |
| 016 | 2026-07-24T05:04:00Z | 0 | `bash ops/terraform/tests_iac_validation_static.sh` | `command_outputs/016_metering_bootstrap_contract.txt` |
| 017 | 2026-07-24T05:06:05Z | 0 | Fetch and freeze accepted `origin/main`; prove `e36327f4b` ancestry | `command_outputs/017_freeze_origin_main.txt` |
| 018 | 2026-07-24T05:06:37Z | 0 | Prepare a clean detached worktree at the accepted `origin/main` SHA | `command_outputs/018_prepare_accepted_worktree.txt` |
| 019 | 2026-07-24T05:08:16Z | 0 | `debbie sync staging --dry-run` from the clean accepted-SHA worktree | `command_outputs/019_debbie_staging_dry_run.txt` |
| 020 | 2026-07-24T05:08:51Z | 0 | `debbie sync staging` from the clean accepted-SHA worktree | `command_outputs/020_debbie_sync_staging.txt` |
| 021 | 2026-07-24T05:11:48Z | 0 | Assert the clean staging mirror manifest names the accepted dev SHA and copy it into the evidence bundle | `command_outputs/021_staging_sync_receipt.txt` |
| 022 | 2026-07-24T05:12:42Z | 1 | Run the accepted-SHA `verify_e2e_deployed_gate.sh`; mirror CI terminated before deployment | `command_outputs/022_verify_e2e_deployed_gate.txt` |
| 023 | 2026-07-24T05:16:55Z | 0 | Preserve the gate failure receipt and diagnose the failed mirror job | `command_outputs/023_deploy_gate_failure_diagnosis.txt` |

## Session 3: Deploy gate retry with auth-fix SHA

### 2026-07-24T06:30:21Z — Freeze new accepted SHA
```
git fetch origin
# exit: 0
git rev-parse origin/main
# efdbfd1989e6127860c1a2131202b6af624fe089
git merge-base --is-ancestor c7ed719ee origin/main
# exit: 0 — auth fix is ancestor
git merge-base --is-ancestor fa7fc6a26 origin/main
# exit: 0 — metering repair is ancestor
```
Updated ACCEPTED_SHA.txt from 11737bafecc8def4174c3f6bbfaa9ee0f7e166da to efdbfd1989e6127860c1a2131202b6af624fe089.
Reason: prior accepted SHA failed CI because auth verification test bug was present; fix c7ed719ee has since landed on origin/main.

## Session 11: Postdeploy runtime convergence and final green proof

| ID | UTC start | Exit | Command | Bounded stdout/stderr |
| --- | --- | ---: | --- | --- |
| 024 | 2026-07-24T08:44:00Z | 0 | `bash scripts/deploy_status.sh --json --env staging` | `command_outputs/024_deploy_status_json.txt` |
| 025 | 2026-07-24T08:44:00Z | 0 | `curl -fsS https://api.staging.flapjack.foo/version` | `command_outputs/025_version_json.txt` |
| 026 | 2026-07-24T08:45:00Z | 0 | Initial postdeploy `usage_daily` and `usage_records` SQL | `command_outputs/026_final_usage_sql.txt` |
| 027 | 2026-07-24T08:45:00Z | 0 | Initial postdeploy `bash scripts/probe_live_state.sh` | `command_outputs/027_probe_live_state_postdeploy.txt` |
| 028 | 2026-07-24T08:48:00Z | 0 | Postdeploy aggregation service/timer status | `command_outputs/028_postdeploy_systemd_status.txt` |
| 029 | 2026-07-24T08:49:00Z | 0 | Data-plane `fj-metering-agent` status and 403 journals | `command_outputs/029_dataplane_metering_status.txt` |
| 030 | 2026-07-24T08:49:00Z | 0 | Data-plane env key-shape comparison | `command_outputs/030_dataplane_metering_env_shape.txt` |
| 031 | 2026-07-24T08:51:00Z | 0 | Converge accepted staging runtime artifacts onto data-plane nodes | `command_outputs/031_dataplane_converge_metering_runtime.txt` |
| 032 | 2026-07-24T08:52:00Z | 0 | SQL check after runtime artifact convergence | `command_outputs/032_post_converge_usage_records_sql.txt` |
| 033 | 2026-07-24T08:53:00Z | 0 | Data-plane journal/curl check after artifact convergence | `command_outputs/033_post_converge_metering_journal_and_curl.txt` |
| 034 | 2026-07-24T08:53:00Z | 0 | Flapjack process/env probe identifying persisted admin key source | `command_outputs/034_flapjack_env_process_probe.txt` |
| 035 | 2026-07-24T08:57:43Z | 0 | Converge persisted Flapjack admin key/app-id on five staging data-plane nodes | `command_outputs/035_dataplane_admin_key_converge.txt` |
| 036 | 2026-07-24T08:59:35Z | 0 | SQL check after admin-key convergence | `command_outputs/036_post_admin_key_usage_records_sql.txt` |
| 037 | 2026-07-24T09:00:03Z | 0 | Metering journal after admin-key convergence | `command_outputs/037_post_admin_key_metering_journal.txt` |
| 038 | 2026-07-24T09:00:49Z | 0 | Synthetic tenant A provision-only run | `command_outputs/038_seed_synthetic_tenant_a_provision_only.txt` |
| 039 | 2026-07-24T09:01:20Z | 0 | Resolve seeded tenant node by tag | `command_outputs/039_resolve_seeded_tenant_node.txt` |
| 040 | 2026-07-24T09:01:53Z | 0 | Seeded node DNS/SSM catalog probe | `command_outputs/040_seeded_node_dns_ssm_catalog.txt` |
| 041 | 2026-07-24T09:02:08Z | 0 | Resolve seeded tenant node by public IP | `command_outputs/041_seeded_node_ec2_by_public_ip.txt` |
| 042 | 2026-07-24T09:02:40Z | 0 | Converge persisted admin key on seeded tenant node | `command_outputs/042_seeded_node_admin_key_converge.txt` |
| 043 | 2026-07-24T09:03:37Z | 1 | Superseded direct-write wrapper using reserved zsh `status` variable | `command_outputs/043_seeded_tenant_direct_write.txt` |
| 043b | 2026-07-24T09:03:59Z | 0 | Direct write to seeded tenant after wrapper fix | `command_outputs/043b_seeded_tenant_direct_write.txt` |
| 044 | 2026-07-24T09:05:33Z | 0 | SQL check after seeded direct write | `command_outputs/044_post_direct_write_usage_records_sql.txt` |
| 045 | 2026-07-24T09:06:08Z | 1 | Tenant-map/storage/journal probe showing prod API URL in staging metering env | `command_outputs/045_seeded_node_tenant_map_and_journal.txt` |
| 046 | 2026-07-24T09:08:48Z | 0 | Resolve all running data-plane nodes with `node_id` tags | `command_outputs/046_resolve_all_running_dataplane_nodes.txt` |
| 047 | 2026-07-24T09:09:26Z | 0 | First staging URL convergence attempt | `command_outputs/047_dataplane_staging_url_converge.txt` |
| 048 | 2026-07-24T09:10:31Z | 1 | Failed forced-env convergence; literal API_BASE_URL runtime mistake | `command_outputs/048_force_staging_dataplane_env_converge.txt` |
| 049 | 2026-07-24T09:11:15Z | 0 | Repair literal runtime env mistake and force staging URLs on all six nodes | `command_outputs/049_repair_literal_api_base_runtime_env.txt` |
| 050 | 2026-07-24T09:11:57Z | 0 | Direct write after staging URL convergence | `command_outputs/050_seeded_tenant_direct_write_after_url_fix.txt` |
| 051 | 2026-07-24T09:13:28Z | 0 | SQL check after post-fix seeded write | `command_outputs/051_post_url_fix_usage_records_sql.txt` |
| 052 | 2026-07-24T09:13:58Z | 0 | Seeded node journal showing DB pool timeout and prod-VPC placement | `command_outputs/052_seeded_node_post_url_fix_journal.txt` |
| 053 | 2026-07-24T09:14:22Z | 0 | Seeded node and staging RDS security-group probe | `command_outputs/053_live_db_security_group_probe.txt` |
| 054 | 2026-07-24T09:14:41Z | 0 | All data-plane node security-group inventory | `command_outputs/054_all_dataplane_security_groups.txt` |
| 055 | 2026-07-24T09:15:06Z | 254 | Attempt to attach seeded node to staging SG; AWS rejected cross-VPC SG mutation | `command_outputs/055_seeded_node_security_group_fix.txt` |
| 056 | 2026-07-24T09:15:48Z | 56 | Superseded existing staging tenant write with wrong internal token | `command_outputs/056_write_existing_staging_tenant.txt` |
| 056b | 2026-07-24T09:16:18Z | 0 | Direct write to existing staging tenant on `vm-shared-f2b9c8a6.flapjack.foo` | `command_outputs/056b_write_existing_staging_tenant.txt` |
| 057 | 2026-07-24T09:17:56Z | 0 | SQL check showing fresh `usage_records` after existing staging tenant write | `command_outputs/057_existing_staging_tenant_usage_records_sql.txt` |
| 058 | 2026-07-24T09:18:25Z | 1 | Superseded aggregation wrapper with local `%F` printf error | `command_outputs/058_run_aggregation_job_current_day.txt` |
| 058b | 2026-07-24T09:18:40Z | 1 | Aggregation run without exporting env file variables | `command_outputs/058b_run_aggregation_job_current_day.txt` |
| 059 | 2026-07-24T09:19:07Z | 0 | API-host env shape and aggregation unit check | `command_outputs/059_api_host_env_shape_for_aggregation.txt` |
| 060 | 2026-07-24T09:19:24Z | 0 | Run aggregation job with exported `/etc/fjcloud/env` and current UTC target date | `command_outputs/060_run_aggregation_job_current_day.txt` |
| 061 | 2026-07-24T09:19:35Z | 0 | Final SQL check showing fresh `usage_daily` and `usage_records` | `command_outputs/061_post_aggregation_usage_daily_sql.txt` |
| 062 | 2026-07-24T09:19:58Z | 0 | Final canonical `bash scripts/probe_live_state.sh` | `command_outputs/062_probe_live_state_final.txt` |
| 063 | 2026-07-24T09:23:00Z | 0 | Copy final live-state summary/raw JSON and render staging row | `command_outputs/063_final_live_state_staging_row.txt`, `command_outputs/064_final_live_state_copy_receipt.txt` |
