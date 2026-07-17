# SES Coverage A1 Stage 3 Terminal Staging Evidence Summary

Bundle path: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun`
Run UTC: `20260711T221212Z`
Billing month: `2026-06`
HEAD SHA: `c6c9054dd050fe4b21844280fa251fdefe43a4a7`
Terminal deployed SHA: `b0fc91ff9580e5e79d7c4f5a0d4576f41e55f4ff`

## Verification Termini

- AWS caller identity: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/aws_identity.json`.
- Staging deployed state: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/deploy_status_staging.json` and `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/staging_version_after.json`.
- EC2 staging instance discovery: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/ec2_instance_discovery.json`.
- SSM reachability: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/ssm_target_preflight.json`.
- Secret preflight: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/secret_preflight_evidence.txt` confirms test Stripe key prefix and tenant allowlist presence without printing values.
- Remote checkout/env setup: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/tarball_build_evidence.txt`, `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/s3_upload.log`, `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/host_checkout.log`, and `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/host_env_materialize.log`.
- Probe logs and sidecars: six `*.log` files and six `*.json` sidecars.
- Parser integrity: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/integrity_check.log`.

## Probe Results

```tsv
probe_id	rc	pass	log_path
verify_email_clickthrough	1	0	docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/verify_email_clickthrough.log
password_reset_clickthrough	1	0	docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/password_reset_clickthrough.log
dunning_email_inbox	1	0	docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/dunning_email_inbox.log
ses_bounce	0	1	docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/ses_bounce.log
ses_complaint	0	1	docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/ses_complaint.log
staging_dunning_delivery	1	0	docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/staging_dunning_delivery.log
```

## Disposition

- `all_green.txt=0`.
- Parser-passing rows: `['ses_bounce', 'ses_complaint']`.
- Branch rule: Stage 2 classified both residuals as probe-side, so they retire only when this deployed six-row bundle is all green.
- Terminal bundle is not green. Probe-side residuals cannot be retired because these rows are non-green: ['verify_email_clickthrough', 'password_reset_clickthrough', 'dunning_email_inbox', 'staging_dunning_delivery']. Section 1 status owners must remain partial and cite this bundle.
- Non-green classifications, if any, are in `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/failure_classifications.json` and `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun/GAP_SPEC.md`.
