# SES Inbox/Canary Clean-Env Summary

Bundle: `docs/runbooks/evidence/ses-inbox-canary-clean-env/20260709T104734Z/`

This root summary closes the Stage 4 operator bundle by pointing at the
probe-owned verdicts from Stages 1-3. Per-probe transcripts and detailed failure
evidence remain owned by `ses/`, `inbound-roundtrip/`, and `canary/`.

## Provenance

- Bundle-wide credential proof: [`STS_IDENTITY_SUMMARY.md`](STS_IDENTITY_SUMMARY.md).
- Stage 1 live-state snapshot cited by the SES verdict:
  `docs/live-state/20260709T104734Z/SUMMARY.md`.
- Stage 2 live-state pointer: `inbound-roundtrip/live_state_pointer.txt`.
- Stage 3 live-state and canary readback evidence: `canary/probe_live_state.*`
  and `canary/probe_canary_live_state_staging.*`.

The later `docs/live-state/20260709T112924Z/` snapshot is not promoted into this
root summary because the probe-owned verdicts do not cite it as their source.

## Probe Verdicts

| Stage | Owner | Verdict | Current blocker or disposition |
| --- | --- | --- | --- |
| Stage 1 SES bounce/complaint | `scripts/probe_ses_bounce_complaint_e2e.sh::main` | Not green | Both `ses_bounce` and `ses_complaint` stopped at preflight because `DATABASE_URL|INTEGRATION_DB_URL` was missing, so suppression/audit side effects were not exercised. |
| Stage 2 inbound roundtrip | `scripts/validate_inbound_email_roundtrip.sh` | PASS | Automated S3-backed `*@test.flapjack.foo` round-trip passed, including send, S3 poll, RFC822 fetch, and DKIM/SPF/DMARC authentication checks. |
| Stage 3 customer-loop canary | `scripts/probe_canary_live_state.sh` | Not green | Credentials are clean, but readback still reports `errors_24h` and `last_invocation` failures; captured log evidence names `signup` HTTP 429. |

## Lane Disposition

The clean-env rerun cleared the stale AWS credential explanation for this lane:
Stages 1-3 all used `arn:aws:iam::213880904778:user/stuart-cli`. The lane is not
green yet because the remaining blockers are owner-specific:

- Stage 1 needs `DATABASE_URL|INTEGRATION_DB_URL` available before
  `scripts/probe_ses_bounce_complaint_e2e.sh::main` can exercise SES suppression
  and audit side effects.
- Stage 2 is green for the automated inbound S3 round-trip path.
- Stage 3 needs the customer-loop canary owner to resolve the `signup` HTTP 429
  failure and the resulting `errors_24h` / `last_invocation` readback failures.
