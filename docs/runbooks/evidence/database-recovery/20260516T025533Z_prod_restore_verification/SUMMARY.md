# RDS restore verification evidence (prod)
# target_endpoint: fjcloud-prod-restore-20260516025535.cabwlew6jcjl.us-east-1.rds.amazonaws.com
# source_db_instance_id: fjcloud-prod
# restore_mode: pitr (selected_restore_time=2026-05-16T02:09:35+00:00)
# captured_at: 2026-05-16T03:40:10Z
# db_engine: postgres 17.6 (RDS)
# captured_by: may15_9pm_2_prod_rds_restore_drill + docs/runbooks/database-backup-recovery.md
# result: pass
# data_state: Restored target sanity queries and migration parity passed. Query outputs in stage3 artifacts should be treated as authoritative for row counts; migration parity reports target_count=45, target_max_version=46.
# NOTE: unlike the 2026-04-23 staging evidence (single .txt file), this prod proof is an intentional directory bundle because the drill produced four stage-scoped artifact sets.

## Stage Verdicts

| Stage | State file | Verdict | Reason |
| --- | --- | --- | --- |
| Stage 1 preflight | state/stage1_preflight_state.json | pass | preflight captured and restore request selected |
| Stage 2 restore execute | state/stage2_restore_state.json | pass | success |
| Stage 3 restore verify | state/stage3_verification_state.json | pass | target_sanity_queries_succeeded_and_migration_parity_passed |
| Stage 4 cleanup | state/stage4_cleanup_state.json | pass | target_deleted_and_no_network_residue |

## Artifact Index

- stage1_preflight/: discovery.json, restore_request.json, summary.json, verification.sql, verification.txt
- stage2_restore_execute/: wrapper-produced restore evidence directory copy
- stage3_restore_verify/: target_verification.txt, migration_parity.txt, comparison_summary.json
- stage4_cleanup/: delete_command.json, deletion_absence_probe.json, network_residue_assertion.json, target_describe_before_delete.json, target_describe_after_delete.json, source_sg_describe.json
- state/: stage1_preflight_state.json, stage2_restore_state.json, stage3_verification_state.json, stage4_cleanup_state.json
