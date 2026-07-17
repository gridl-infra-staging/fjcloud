# SES Inbox/Canary Clean-Env Summary

Bundle: `docs/runbooks/evidence/ses-inbox-canary-clean-env/20260711T014655Z/`

This fresh Stage 4 bundle RAN the live SES bounce/complaint probes, exercised inbound support email roundtrip, and exercised the customer-loop canary against live staging.

## Provenance

- Credential proof: [`STS_IDENTITY_SUMMARY.md`](STS_IDENTITY_SUMMARY.md).
- Live-state command output: `probe_live_state.stdout` captured the script-reported snapshot path.
- SES production access evidence: `ses/production_access.stdout`.
- SES owner outputs: `ses/ses_bounce.*` and `ses/ses_complaint.*`.
- Inbound owner output: `inbound-roundtrip/validate_inbound_email_roundtrip.*`.
- Canary owner outputs: `canary/lambda_canary_invoke_contract.*` and `canary/probe_canary_live_state.*`.

## Probe Verdicts

| Stage | Owner | Verdict | Evidence |
| --- | --- | --- | --- |
| Stage 2 SES bounce/complaint | `scripts/probe_ses_bounce_complaint_e2e.sh::main` | PASS | RAN bounce and complaint against live staging; both exercised `poll_sns_side_effects`, second-send suppression, and cleanup. |
| Inbound roundtrip | `scripts/validate_inbound_email_roundtrip.sh` | PASS | RAN automated S3-backed `*@test.flapjack.foo` roundtrip with send, S3 poll, RFC822 fetch, and DKIM/SPF/DMARC checks. |
| Stage 3 customer-loop canary | `scripts/canary/contracts/lambda_canary_invoke_contract.sh` + `scripts/probe_canary_live_state.sh` | PASS | Exercised synchronous Lambda invoke and readback; invoke returned PASS, readback has `errors_24h == 0` and `last_invocation` success. |

## Lane Disposition

The clean-env lane is green at this bundle. SES bounce reason/source/audit were `bounce_permanent_general` / `ses_sns_webhook` / `ses_permanent_bounce_suppressed`; complaint reason/source/audit were `complaint` / `ses_sns_webhook` / `ses_complaint_suppressed`. The customer-loop canary readback is ready with all checks passing.
