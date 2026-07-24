# Postdeploy runtime repair

Accepted deploy state:
`7b5584e85dda27e7e6066d4eadb54bc604ac466b` reached staging and passed the
deployed gate, but the first postdeploy freshness probe still rendered
`usage_rollup_freshness_staging` as `ACTION_REQUIRED`.

Demonstrated runtime defects:

- Flapjack nodes had `/etc/fjcloud/metering-env` API keys, but Flapjack itself
  loaded its admin key from `/var/lib/flapjack/data/.admin_key`; direct
  `/metrics` and `/internal/storage` calls returned HTTP 403. Receipts:
  `command_outputs/029_dataplane_metering_status.txt`,
  `command_outputs/034_flapjack_env_process_probe.txt`.
- Staging metering agents pointed at `https://api.flapjack.foo/internal/*`,
  so tenant-map attribution was sourced from prod. Receipt:
  `command_outputs/045_seeded_node_tenant_map_and_journal.txt`.
- The synthetic seeder's fallback shared-node discovery used the unscoped SSM
  node-key catalog and selected a prod-VPC node for staging evidence. Receipts:
  `command_outputs/038_seed_synthetic_tenant_a_provision_only.txt`,
  `command_outputs/053_live_db_security_group_probe.txt`,
  `command_outputs/055_seeded_node_security_group_fix.txt`.

Repairs in this commit:

- `ops/user-data/bootstrap.sh` and
  `infra/api/src/provisioner/cloud_init.rs` now persist the Flapjack admin key,
  write `FLAPJACK_APPLICATION_ID=flapjack`, and derive metering internal URLs
  from an environment-aware API base.
- `scripts/launch/seed_synthetic_traffic.sh` now discovers shared fallback
  nodes from EC2 using the target environment's Flapjack VM security group
  instead of the unscoped SSM key catalog.

Live convergence:

- `command_outputs/049_repair_literal_api_base_runtime_env.txt` shows all six
  running staging data-plane nodes using
  `https://api.staging.flapjack.foo/internal/tenant-map`.
- `command_outputs/056b_write_existing_staging_tenant.txt` writes one document
  to an existing staging tenant on `vm-shared-f2b9c8a6.flapjack.foo`.
- `command_outputs/057_existing_staging_tenant_usage_records_sql.txt` shows
  fresh `usage_records` after the write.
- `command_outputs/060_run_aggregation_job_current_day.txt` reruns aggregation
  for `2026-07-24`.
- `command_outputs/061_post_aggregation_usage_daily_sql.txt` and
  `postdeploy_usage_rollup_freshness_staging.json` are the final green SQL and
  classifier evidence.
