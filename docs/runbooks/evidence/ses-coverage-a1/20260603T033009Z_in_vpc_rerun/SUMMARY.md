# Stage 4 Section 1 In-VPC Rerun Summary

Bundle: `docs/runbooks/evidence/ses-coverage-a1/20260603T033009Z_in_vpc_rerun`

## Verdict

`all_green.txt` is `0`. All six rows are non-green in this run; no probe result is treated as verified pass without its log and sidecar.

## Index

- `run_manifest.txt` - UTC run id, `head_sha`, billing month, owner paths, staging-only scope, SSM target, and transport prefix.
- `ssm_target_preflight.json` - exact staging instance SSM freshness evidence.
- `reference_bundle_comparison.md` - comparison against the May 29 and May 28 reference bundle shapes, including the May 28 missing-local-log caveat.
- `secret_preflight_evidence.txt` - redacted post-capture proof that the canonical secret source still satisfies the `sk_test_*` and `FJCLOUD_TEST_TENANT_IDS` gates without printing values.
- `tarball_build.log`, `tarball_build_evidence.txt`, `s3_upload.log`, `host_checkout.log`, `host_env_materialize.log` - setup evidence. `tarball_build.log` is zero bytes because the local tar command was quiet; `tarball_build_evidence.txt`, `s3_upload.log`, and `host_checkout.log` preserve the transport proof. `host_env_materialize.log` lists key names only.
- `probe_results.tsv` - six canonical `probe_id rc pass log_path` rows.
- `verify_email_clickthrough.log` / `.json`
- `password_reset_clickthrough.log` / `.json`
- `dunning_email_inbox.log` / `.json`
- `ses_bounce.log` / `.json`
- `ses_complaint.log` / `.json`
- `staging_dunning_delivery.log` / `.json`
- `all_green.txt` - `1` only if every row has `rc=0` and `pass=1`; this run is `0`.
- `failure_classifications.json` and `GAP_SPEC.md` - required because the run is non-green.
- `host_cleanup.log`, `s3_cleanup.log` - remote checkout and S3 transport cleanup evidence.
- `verification_commands.txt` - exact command shapes used for preflight, SSM setup, six probes, cleanup, and integrity validation.
- `stage4_integrity.py` - committed parser used to re-validate the bundle from saved logs at current HEAD.

## Verification Termini

- AWS identity and target state were captured by direct `aws sts get-caller-identity`, `aws ec2 describe-instances`, and `aws ssm describe-instance-information` calls before `send-command`.
- The probe logs are direct stdout/stderr captures from `scripts/launch/ssm_exec_staging.sh` RunShellScript invocations against `Name=fjcloud-api-staging`.
- Sidecar JSON and `probe_results.tsv` were regenerated from saved logs at current HEAD using the pass contracts in the owner scripts.
- The final integrity command recorded in `integrity_check.log` checks required file existence, non-empty probe logs, JSON parseability, probe-id alignment, sidecar/log agreement, `all_green.txt` consistency, and source-of-truth pass detection from logs.

## Exact Integrity Command

```bash
python3 docs/runbooks/evidence/ses-coverage-a1/20260603T033009Z_in_vpc_rerun/stage4_integrity.py \
  docs/runbooks/evidence/ses-coverage-a1/20260603T033009Z_in_vpc_rerun
```

The concrete output from this run is saved in `integrity_check.log`.
