# Stage 3 result — cleanup of isolated RDS restore target

- target_name: fjcloud-staging-restore-20260612002802
- region: us-east-1
- delete_command_dispatched_at_utc: 2026-06-12T00:44:39Z
- delete_command: `aws rds delete-db-instance --db-instance-identifier fjcloud-staging-restore-20260612002802 --skip-final-snapshot --region us-east-1`
- delete_api_response_status: deleting (see `delete_db_instance_response.json`)
- post_delete_followup_status: deleting (see `cleanup_restore_target_status.txt`)
- bundle_path: docs/runbooks/evidence/database-recovery/20260612T002802Z_current_main
- bundle_path_repo_relative: docs/runbooks/evidence/database-recovery/20260612T002802Z_current_main

## Scope discipline

- `fjcloud-staging` (source instance) was NOT touched — only `$TARGET_NAME` was passed to
  `aws rds delete-db-instance`, and a pre-delete guard asserted
  `[ "$TARGET_NAME" != "fjcloud-staging" ]` and the `fjcloud-staging-restore-` prefix.
- No restore scripts under `ops/scripts/` were modified.
- `ops/scripts/lib/rds_restore_selection.py` was not touched.
- Terraform state, LAUNCH matrix, and `ROADMAP.md` were not edited.

## Evidence files added by Stage 3

- `target_describe_pre_delete.json` — durable pre-delete fingerprint (status=available).
- `delete_db_instance_response.json` — AWS API response to the delete call.
- `cleanup_restore_target_status.txt` — post-delete describe output (status=deleting).
- `STAGE3_RESULT.md` — this summary.

## Notes

- A single delete call was issued (no retries). The follow-up describe confirmed
  `DBInstanceStatus: deleting`; no `DBInstanceNotFound` was needed because the API
  returns the deleting state before the instance is fully removed.
- The `--skip-final-snapshot` flag was used as specified by the checklist; no
  `--final-db-snapshot-identifier` was passed. This is the intended terminal action for
  an isolated restore drill target — the restore was for rehearsal, not for promotion.
- Stage 4 owns updating `ROADMAP.md` / `docs/launch_verification_matrix.md` and rerunning
  contract seams + `scripts/local-ci.sh --fast`.
