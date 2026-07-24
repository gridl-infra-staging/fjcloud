# Current Stage 1 inputs

- `origin/main`: `7b5584e85dda27e7e6066d4eadb54bc604ac466b`
- Local Batman HEAD at final evidence capture: `68066818523ce7f1a40cfe8d5692f10f1a750c3e`
- Accepted SHA for Debbie/gate/deploy-status/version proof:
  `7b5584e85dda27e7e6066d4eadb54bc604ac466b`.
- Accepted predecessor repair ancestry: `git merge-base --is-ancestor
  fa7fc6a26 origin/main` exited 0.
- Banked artifact proof:
  `command_outputs/003_banked_artifact_tree.txt`
- Live-state registration proof:
  `command_outputs/004_live_state_registration.txt`
- Local-CI registration proof:
  `command_outputs/005_local_ci_registration.txt`
- AWS caller identity: account `213880904778`, principal
  `arn:aws:iam::213880904778:user/stuart-cli`; the clean-shell STS command
  exited 0. Receipt: `command_outputs/007_aws_caller_identity.txt`.
- Debbie staging mirror proof: `sync_manifest_attempt_03.json` records the
  accepted dev SHA, and `deployed_gate_attempt_03/SUMMARY.PASS.md` records
  `deploy-staging` and `e2e-deployed` success for run `30077247118`.
- Deploy currency proof: `command_outputs/024_deploy_status_json.txt` and
  `command_outputs/025_version_json.txt` both report the accepted dev SHA.
- Final live proof: `command_outputs/061_post_aggregation_usage_daily_sql.txt`
  shows `usage_daily` fresh rows = 1 and `usage_records` fresh rows = 5;
  `postdeploy_usage_rollup_freshness_staging.json` reports
  `fresh_rows: 1` and `latest_aggregated_at:
  2026-07-24T09:19:25.402867Z`; `POSTDEPLOY_LIVE_STATE_SUMMARY.md` renders
  `usage_rollup_freshness_staging` as `OK`.

The evidence captured in this bundle is fresh Stage 1 evidence and supersedes
the predecessor lane's staging row counts, staging-currency claim, and
credential claim.
