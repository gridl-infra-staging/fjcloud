# Stage 3 Gap Spec

## Trigger condition
- Live-path deploy verification failed during `bash ops/scripts/deploy.sh staging <HEAD_SHA>`.
- Evidence: `stage3/live_path_deploy_staging.log`.

## Exact failing gate/check
- Failure occurred inside SSM-run deploy step while downloading release binary from S3:
  - `HeadObject 404` for key `staging/338ce7158edd82f0a7a7d83144c17cf581878049/fjcloud-api`.
- This breaks the Stage 3 requirement to prove staging deploy works under rotated IAM scope.

## Blast radius
- IAM apply made zero changes (`0 added, 0 changed, 0 destroyed`) and no delete/replace actions were present in plan scope gate.
- Failed deploy attempt did not rotate to the new SHA on instance due early artifact download failure.
- Potential transient side effect was SSM parameter update for `last_deploy_sha`, but rollback flow restored policy/state posture and post-rollback runtime checks passed.

## Rollback result
- Executed rollback using Stage 2 backups:
  - Restored local Terraform state files from `state_backup/`.
  - Re-applied pre-apply trust and inline policy snapshots for all managed roles.
  - Re-captured post-rollback snapshots and verified trust/inline policies exactly match pre-apply artifacts (`stage3/rollback/post_rollback_posture_diff.json`).
- Post-rollback focused validations passed:
  - `bash ops/terraform/tests_stage8_static.sh`
  - `cd ops/iam && terraform validate`
  - `bash ops/terraform/tests_stage7_runtime_smoke.sh --env staging --domain flapjack.foo --ami-id ami-078228dbe86117d85 --env-file .secret/.env.secret`

## Minimal next change before re-attempting apply
- Publish release artifacts for the exact deployment SHA to `s3://fjcloud-releases-staging/staging/<sha>/` (at minimum `fjcloud-api`, plus expected deploy payload files).
- Re-run Stage 3 live-path verification using a SHA with confirmed artifact presence before another guarded apply attempt.
