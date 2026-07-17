# SES Coverage A1 In-VPC Rerun Summary

Bundle path: `docs/runbooks/evidence/ses-coverage-a1/20260604T114841Z_in_vpc_rerun`
Verdict: `all_green=0`
Run UTC: `20260604T114841Z`
Bundle head SHA: `a08b9eb746186b2d641cc1a147f8115fa5e3d513`

## File Index

- `GAP_SPEC.md`
- `COMMAND_PROVENANCE.md`
- `SUMMARY.md`
- `all_green.txt`
- `aws_identity.json`
- `dunning_email_inbox.json`
- `dunning_email_inbox.log`
- `ec2_instance_discovery.json`
- `failure_classifications.json`
- `host_checkout.log`
- `host_cleanup.log`
- `host_env_materialize.log`
- `integrity_check.log`
- `password_reset_clickthrough.json`
- `password_reset_clickthrough.log`
- `probe_results.tsv`
- `reference_bundle_comparison.md`
- `run_manifest.txt`
- `s3_cleanup.log`
- `s3_upload.log`
- `secret_preflight_evidence.txt`
- `ses_bounce.json`
- `ses_bounce.log`
- `ses_complaint.json`
- `ses_complaint.log`
- `ssm_target_preflight.json`
- `stage4_integrity.py`
- `staging_dunning_delivery.json`
- `staging_dunning_delivery.log`
- `tarball_build.log`
- `tarball_build_evidence.txt`
- `verification_commands.txt`
- `verify_email_clickthrough.json`
- `verify_email_clickthrough.log`

## Verification Termini

- AWS caller identity: `docs/runbooks/evidence/ses-coverage-a1/20260604T114841Z_in_vpc_rerun/aws_identity.json`.
- EC2 instance discovery: `docs/runbooks/evidence/ses-coverage-a1/20260604T114841Z_in_vpc_rerun/ec2_instance_discovery.json` reports staging instance `i-0fbc6d6bbbc8bdc6d`.
- SSM reachability: `docs/runbooks/evidence/ses-coverage-a1/20260604T114841Z_in_vpc_rerun/ssm_target_preflight.json` reports `PingStatus=Online` for `i-0fbc6d6bbbc8bdc6d`.
- Secret preflight: `docs/runbooks/evidence/ses-coverage-a1/20260604T114841Z_in_vpc_rerun/secret_preflight_evidence.txt` confirms a test Stripe key prefix and tenant allowlist presence without printing secret values.
- Command provenance: `docs/runbooks/evidence/ses-coverage-a1/20260604T114841Z_in_vpc_rerun/COMMAND_PROVENANCE.md` documents the secret-safe reproduction boundary for `verification_commands.txt`; the tenant allowlist is read from the authorized local secret file at execution time and is not committed.
- Probe stdout/stderr termini: six `*.log` files captured from `scripts/launch/ssm_exec_staging.sh` against `Name=fjcloud-api-staging`.
- Sidecar/TSV termini: six `*.json` sidecars, `probe_results.tsv`, `all_green.txt`, and `failure_classifications.json` were derived from the saved logs and rechecked by `stage4_integrity.py`.
- Stage 1 staging `/version` terminus: `/Users/stuart/.matt/projects/fjcloud_dev-051f15c3/jun04_am_4_invite_ready_section1_evidence_and_rc_verdict.md-eea0cb6e/stage_artifacts/stage_01/version_staging.json` reports `dev_sha=26530584c00b215cec178044fe371bd0d47678db`, `mirror_sha=11644262ae404d658b9a496b41fc5924ffa274f6`, `build_time=2026-06-04T08:05:40Z`.
- Stage 1 prod `/version` terminus: `/Users/stuart/.matt/projects/fjcloud_dev-051f15c3/jun04_am_4_invite_ready_section1_evidence_and_rc_verdict.md-eea0cb6e/stage_artifacts/stage_01/version_prod.json` reports `dev_sha=26530584c00b215cec178044fe371bd0d47678db`, `mirror_sha=fde00924ab49e4dabccecb58c471f66af6e317cb`, `build_time=2026-06-04T08:06:51Z`.
- Stage 1 pre-flight live-state bundle: `/Users/stuart/.matt/projects/fjcloud_dev-051f15c3/jun04_am_4_invite_ready_section1_evidence_and_rc_verdict.md-eea0cb6e/stage_artifacts/stage_01/deploy_status.json` reports both staging and prod deployed dev SHAs as `26530584c00b215cec178044fe371bd0d47678db`, with both environments `commits_behind_main=47` relative to `dev_main_sha=802e16e09c3cc47a4fa3e553a286756b5c9b1610`.

## Probe Results

- `verify_email_clickthrough`: rc=1 pass=0, classification=`verify_email_token_invalid_or_expired`.
- `password_reset_clickthrough`: rc=1 pass=0, classification=`password_reset_token_not_cleared`.
- `dunning_email_inbox`: rc=1 pass=0, classification=`rehearsal_reset_failed`.
- `ses_bounce`: rc=0 pass=1.
- `ses_complaint`: rc=0 pass=1.
- `staging_dunning_delivery`: rc=1 pass=0, classification=`stripe_cli_missing`.

## Disposition

- Non-green bundle. New failure shapes relative to the reference: `verify_email_token_invalid_or_expired` and `stripe_cli_missing`.
- Conditional disposition: do not proceed to flip Section 1 live from this bundle. Repoint partial evidence only, and route the new shapes to repair before a live flip.

## Integrity Command

```bash
python3 docs/runbooks/evidence/ses-coverage-a1/20260604T114841Z_in_vpc_rerun/stage4_integrity.py docs/runbooks/evidence/ses-coverage-a1/20260604T114841Z_in_vpc_rerun > docs/runbooks/evidence/ses-coverage-a1/20260604T114841Z_in_vpc_rerun/integrity_check.log 2>&1
```
