# Stage 4 Prod Gate Summary

- Frozen candidate dev SHA: 9e2e6861c56d4598587538099953086d2604ea93
- Pushed prod mirror SHA: 3f4370ff52acf7a96e989a949eeb9dbc64169569
- Effective dev SHA in pushed prod mirror manifest: 8599b33a41d32f9fba662b47e1bd747ee51dbde8
- Pushed prod commit subject: stage4: republish deploy role scope fix
- CI run ID: 26201800954
- CI run URL: https://github.com/gridl-infra-prod/fjcloud/actions/runs/26201800954
- CI run status: in_progress (advisory playwright still running; all required jobs complete)

## Required Gate Verdicts
- rust-test: success
- rust-lint: success
- migration-test: success
- web-test: success
- check-sizes: success
- web-lint: success
- secret-scan: success
- deploy-prod: success (completed 2026-05-21T03:49:59Z)

## Advisory
- playwright: in_progress (advisory; not in deploy-prod.needs[])

## Failed-to-Green Delta

### Original publication (run 26199594876, SHA 81f96a057bd943a147822cb3a725207f22565f59)
- deploy-prod: failure — `Upload release artifacts` step got `AccessDenied` on `s3:ListBucket` for `arn:aws:s3:::fjcloud-releases-prod`
- Root cause: `ops/iam/github-actions-deploy-role.tf` did not trust `repo:gridl-infra-prod/fjcloud:ref:refs/heads/main` and did not grant S3 access to `fjcloud-releases-prod`

### IAM reconcile (2026-05-21T04:04-04:28Z)
- Terraform apply on `ops/iam/` root added prod repo OIDC trust subject and prod bucket S3 grants
- `Apply complete! Resources: 0 added, 2 changed, 0 destroyed`

### Republish + rerun (run 26201800954, SHA 3f4370ff52acf7a96e989a949eeb9dbc64169569)
- Republished via `debbie sync prod` with IAM fix included
- This republish changed the prod mirror manifest `dev_sha` from the Stage 2 frozen candidate `9e2e6861c56d4598587538099953086d2604ea93` to `8599b33a41d32f9fba662b47e1bd747ee51dbde8`, so the green proof is for the republished artifact, not the original Stage 2 candidate.
- `gh run rerun --failed` reran only failed jobs against same SHA
- deploy-prod: success (completed 2026-05-21T03:49:59Z)
- All 8 required jobs now conclude success
