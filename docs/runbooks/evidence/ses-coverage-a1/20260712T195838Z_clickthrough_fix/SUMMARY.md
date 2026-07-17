# Stage 3 Clickthrough Fix Summary

PURPOSE: Close the Stage 3 staging clickthrough lane using fresh live receipts only. No product code, probe source, host env, SSM parameter, billing/Stripe/dunning state, or API mutation code was changed.

## Outcome

Both live staging clickthrough probes are green.

- Verify-email clickthrough: exit `0`; `email_verified_at` observed true on DB poll attempt `1`.
- Password-reset clickthrough: exit `0`; reset/login succeeded and `password_reset_token` was cleared on DB poll attempt `1`.
- Database-source classification: no drift. `/etc/fjcloud/env`, live process env, and canonical `/fjcloud/staging/database_url` all fingerprint to `sha256_16=a377bb0163e33e75` for `fjcloud-staging.cabwlew6jcjl.us-east-1.rds.amazonaws.com:5432/fjcloud`.
- Target-selection classification: no drift. Exactly one running `fjcloud-api-staging` instance was found, `i-0fbc6d6bbbc8bdc6d`, and the SSM wrapper executed on that instance.

## Receipts

- Baseline reread: `STAGE1_DIAGNOSIS_REREAD.md`
- Live state: `live_state_pointer.md`, `live_state_summary.md`, `probe_live_state_stdout.txt`, `probe_live_state_stderr.txt`, `probe_live_state_exit_code.txt`
- Instance selection: `ec2_running_instances.md`, `ec2_running_instances.json`, `ssm_instance_information.json`
- Database fingerprints: `database_fingerprints.md`, `remote_database_fingerprints.txt`, `canonical_ssm_database_fingerprint.txt`
- Probe logs: `verify_email_clickthrough.log`, `password_reset_clickthrough.log`

## Disposition

No `GAP_SPEC.md` was written because neither probe remained red. The Stage 3 deploy path closed by proof rather than by applying a staging fix.
