# SES Coverage A1 Stage 3 Staging Evidence Summary

Bundle path: `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun`
Run UTC: `20260605T203605Z`
Billing month: `2026-06`
Terminal deployed SHA: `fcf428c4cc1623362278c3b4c0d8f069f285b273`

## Verification Termini

- AWS caller identity: `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/aws_identity.json`.
- EC2 staging instance discovery: `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/ec2_instance_discovery.json`.
- SSM reachability: `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/ssm_target_preflight.json`.
- Secret preflight: `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/secret_preflight_evidence.txt` confirms test Stripe key prefix and tenant allowlist presence without printing values.
- Remote checkout/env setup: `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/tarball_build_evidence.txt`, `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/s3_upload.log`, `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/host_checkout.log`, and `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/host_env_materialize.log`.
- Probe logs and sidecars: six `*.log` files and six `*.json` sidecars.
- Parser integrity: `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/integrity_check.log`.

## Probe Results

```tsv
probe_id	rc	pass	log_path
verify_email_clickthrough	1	0	docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/verify_email_clickthrough.log
password_reset_clickthrough	1	0	docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/password_reset_clickthrough.log
dunning_email_inbox	0	1	docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/dunning_email_inbox.log
ses_bounce	0	1	docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/ses_bounce.log
ses_complaint	0	1	docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/ses_complaint.log
staging_dunning_delivery	0	1	docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/staging_dunning_delivery.log
```

## Disposition

- `all_green.txt=0`.
- Parser-passing rows: `['dunning_email_inbox', 'ses_bounce', 'ses_complaint', 'staging_dunning_delivery']`.
- Non-green classifications are in `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/failure_classifications.json` and `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun/GAP_SPEC.md`.
