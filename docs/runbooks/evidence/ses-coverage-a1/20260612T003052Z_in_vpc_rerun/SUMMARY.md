# SES Coverage A1 Stage 3 Evidence Summary

Bundle path: `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun`
Run UTC: `20260612T003052Z`
Billing month: `2026-06`
Terminal deployed SHA: `d45755199f9725f95cee85fbeaa6f2723f24be8c`

## Canonical Status Files

- Parser: `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/stage4_integrity.py`.
- Probe TSV: `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/probe_results.tsv`.
- Sidecars: `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/verify_email_clickthrough.json`, `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/password_reset_clickthrough.json`, `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/dunning_email_inbox.json`, `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/ses_bounce.json`, `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/ses_complaint.json`, `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/staging_dunning_delivery.json`.
- Aggregate status: `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/all_green.txt`.
- Failure classification: `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/failure_classifications.json` and `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/GAP_SPEC.md`.
- Reference comparison: `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/reference_bundle_comparison.md`.
- Final integrity output: `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/integrity_check.log`.

## Probe Results

```tsv
probe_id	rc	pass	log_path
verify_email_clickthrough	1	0	docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/verify_email_clickthrough.log
password_reset_clickthrough	1	0	docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/password_reset_clickthrough.log
dunning_email_inbox	1	0	docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/dunning_email_inbox.log
ses_bounce	0	1	docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/ses_bounce.log
ses_complaint	0	1	docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/ses_complaint.log
staging_dunning_delivery	1	0	docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/staging_dunning_delivery.log
```

## Disposition

- `all_green.txt=0`.
- Parser-passing rows: `['ses_bounce', 'ses_complaint']`.
- Non-green classifications are in `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/failure_classifications.json` and `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/GAP_SPEC.md`.
- `ses_bounce` remains `rc=0` with sidecar `passed=true`.
- `ses_complaint` remains `rc=0` with sidecar `passed=true`.

## Supporting Stage 2 Scratch Evidence

- Raw Stage 2 status/scratch files retained as supporting evidence only: `probe_results.json`, `probe_run_order.txt`, `preflight_failures.txt`, `aws_identity.err`, `aws_identity.out`, `aws_identity.rc`, `aws_identity_secret_source.err`, `aws_identity_secret_source.out`, `aws_identity_secret_source.rc`, `aws_identity_secret_source_summary.txt`, `stage2_runtime.env`, `ssm_addressability_check.txt`, `instance_id.txt`, `aws_credential_probe.txt`, `host_env_materialize_secret_scan.txt`, `host_env_shape_after_cleanup_probe.log`, and `secret_leak_scan.txt`.
- Current status must not be derived from remote `/tmp/a1_vpc_rerun_20260612T003052Z`, S3, or the scratch `probe_results.json` after this Stage 3 landing.
