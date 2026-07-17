# SES Coverage A1 Stage 2 Staging Evidence Summary

Bundle path: `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun`
Run UTC: `20260605T103646Z`
Billing month: `2026-06`
Stage 1 terminal deployed SHA: `cdd54e601fc7709b224ab95a5c9db2d271cfa2ee`

## Stage 1 Live-State Context

- `stage_artifacts/stage_01/deploy_status_final_s13.json`
- `stage_artifacts/stage_01/version_staging_final_s13.json`
- `stage_artifacts/stage_01/version_prod_final_s13.json`

## Verification Termini

- AWS caller identity: `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/aws_identity.json`.
- EC2 staging instance discovery: `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/ec2_instance_discovery.json`.
- SSM reachability: `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/ssm_target_preflight.json`.
- Secret preflight: `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/secret_preflight_evidence.txt` confirms `STRIPE_SECRET_KEY` test prefix and tenant allowlist presence without printing values.
- Remote checkout/env setup: `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/tarball_build_evidence.txt`, `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/s3_upload.log`, `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/host_checkout.log`, and `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/host_env_materialize.log`.
- Probe logs and sidecars: six `*.log` files and six `*.json` sidecars.
- Parser integrity: `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/integrity_check.log`.

## Probe Results

```tsv
probe_id	rc	pass	log_path
verify_email_clickthrough	1	0	docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/verify_email_clickthrough.log
password_reset_clickthrough	1	0	docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/password_reset_clickthrough.log
dunning_email_inbox	0	1	docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/dunning_email_inbox.log
ses_bounce	0	1	docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/ses_bounce.log
ses_complaint	0	1	docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/ses_complaint.log
staging_dunning_delivery	0	1	docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/staging_dunning_delivery.log
```

## Disposition

- `all_green.txt=0`.
- Section 1 remains partial; new failure shapes are Wave 3 follow-up candidates.
- Classification details are in `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/failure_classifications.json` and `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun/GAP_SPEC.md`.

## Out Of Scope Honored

No probe/runtime code, launch matrix, post-launch follow-up, or verdict docs were changed in this stage.
