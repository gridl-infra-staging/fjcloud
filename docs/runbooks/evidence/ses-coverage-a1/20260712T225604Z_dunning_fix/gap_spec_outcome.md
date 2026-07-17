# Stage 3 gap-spec outcome

## Commands

- `bash scripts/validate_staging_dunning_delivery.sh --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret --month 2026-07 --confirm-live-mutation`
  - rc: `0`
  - stdout: `validator.out`
  - stderr: `validator.err`
  - summary: `validator_summary.json`
- `bash scripts/probe_dunning_email_inbox_e2e.sh --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`
  - rc: `0`
  - stdout: `inbox_probe.out`
  - stderr: `inbox_probe.err`
  - summary: `inbox_probe_summary.json`
- `bash scripts/check_evidence_secret_hygiene.sh`
  - rc: `0`
  - stdout: `secret_hygiene.out`
  - stderr: `secret_hygiene.err`

## Result

- Validator result: `passed`
- Validator classification: `dunning_delivery_verified`
- Validator transitions: all 3 passed (failed, suspended, recovered)
- Inbox probe result: `passed`
- Inbox probe classification: `dunning_delivery_verified`
- Inbox probe detail: Dunning email body contains a Stripe hosted invoice URL
- Secret hygiene: passed
- Staging deploy drift: false (commits_behind_main=0)
- Unit tests: 130 passed, 0 failed

## Diagnosis

Both Stage 3 live probes exit 0 at HEAD `3626058afcf3a8636d23754a79de56cbfed623a0`.
The validator replay fix (commit `2ceac5415`) ensures dunning webhook replay runs even when
rehearsal artifacts already include `transition_invoice_ids`. The staging deploy is current
with no drift. All three dunning transition subjects (Payment retry scheduled, Payment retries
exhausted, Payment recovered) matched inbound RFC822 messages in SES/S3.
