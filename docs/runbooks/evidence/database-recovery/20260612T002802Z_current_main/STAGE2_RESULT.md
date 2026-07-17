# Stage 2 result — live snapshot restore against fjcloud-staging

- env: staging
- source_db_instance_id: fjcloud-staging
- snapshot_id: rds:fjcloud-staging-2026-06-11-02-13
- snapshot_create_time: 2026-06-11T02:13:24Z
- snapshot_type: automated
- target_db_instance_id: fjcloud-staging-restore-20260612002802
- target_status: available
- target_endpoint: fjcloud-staging-restore-20260612002802.cabwlew6jcjl.us-east-1.rds.amazonaws.com
- engine: postgres 17.6
- instance_create_time: 2026-06-12T00:31:59Z
- restore_mode: snapshot
- result: pass
- status: success
- dispatch_completed_at: 2026-06-12T00:36Z (approx)

## Evidence bundle

- run_metadata.env (sourceable for Stage 3-4)
- restore_dispatch.log (stdout/stderr of evidence wrapper)
- rds_restore_evidence_staging_20260612T002909Z_70745/summary.json
- rds_restore_evidence_staging_20260612T002909Z_70745/restore_request.json
- rds_restore_evidence_staging_20260612T002909Z_70745/verification.sql
- rds_restore_evidence_staging_20260612T002909Z_70745/verification.txt
- target_describe_post_dispatch.json (durable proof of isolated target identity/status)

## Notes

- Owner contract was reused unchanged: `ops/scripts/rds_restore_evidence.sh` orchestrated
  discovery, dispatch, polling, and artifact emission; `ops/scripts/rds_restore_drill.sh`
  assembled the AWS `restore-db-instance-from-db-snapshot` command;
  `ops/scripts/lib/rds_restore_selection.py` accepted the explicit `--snapshot-id` and
  selected `restore_mode=snapshot` without PITR fallback.
- Target is the isolated restore instance only; no cutover or DNS swap was performed.
  Cleanup of the restored instance is Stage 3's owner.
