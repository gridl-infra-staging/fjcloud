# SES Coverage A1 Stage 1 Staging Evidence Summary

Bundle path: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun`
Run UTC: `20260711T212915Z`
Billing month: `2026-06`
Same-SHA guard dev_sha: `b0fc91ff9580e5e79d7c4f5a0d4576f41e55f4ff`
Terminal deployed SHA: `b0fc91ff9580e5e79d7c4f5a0d4576f41e55f4ff`
Post-run deploy_status dev_sha: `b0fc91ff9580e5e79d7c4f5a0d4576f41e55f4ff`

## Verification Termini

- Starting deploy status: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/deploy_status_start.json`.
- Post-run deploy status: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/deploy_status_after.json`.
- AWS caller identity: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/aws_identity.json`.
- EC2 staging instance discovery: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/ec2_instance_discovery.json`.
- SSM reachability: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/ssm_target_preflight.json`.
- Secret preflight: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/secret_preflight_evidence.txt` confirms test Stripe key prefix and tenant allowlist presence without printing values.
- Remote checkout/env setup: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/tarball_build_evidence.txt`, `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/s3_upload.log`, `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/host_checkout.log`, and `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/host_env_materialize.log`.
- Probe logs and sidecars: six `*.log` files and six `*.json` sidecars.
- Parser integrity: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/integrity_check.log`.

## Probe Results

```tsv
probe_id	rc	pass	log_path
verify_email_clickthrough	1	0	docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/verify_email_clickthrough.log
password_reset_clickthrough	1	0	docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/password_reset_clickthrough.log
dunning_email_inbox	1	0	docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/dunning_email_inbox.log
ses_bounce	0	1	docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/ses_bounce.log
ses_complaint	0	1	docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/ses_complaint.log
staging_dunning_delivery	1	0	docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/staging_dunning_delivery.log
```

## Disposition

- `all_green.txt=0`.
- Parser-passing rows: `['ses_bounce', 'ses_complaint']`.
- Non-green classifications are in `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/failure_classifications.json` and `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/GAP_SPEC.md`.

## Stage 1 Validation

Same-SHA `dev_sha`: `b0fc91ff9580e5e79d7c4f5a0d4576f41e55f4ff`

Passing validation commands:

- `python3 docs/runbooks/evidence/ses-coverage-a1/20260711T212230Z_in_vpc_rerun/stage4_integrity.py docs/runbooks/evidence/ses-coverage-a1/20260711T212230Z_in_vpc_rerun`
- `python3 docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/stage4_integrity.py docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun`
- `test -s docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun/classification.md`
