# Signup Email Verification Failure — Operator One-Pager

## Trigger symptoms
- Customer reports no verification email after signup.
- Support inbox receives repeated signup verification complaints.
- SES bounce/complaint alert activity increases.

## Immediate checks (first 10 minutes)
1. Check SES account sending posture:
   - `aws sesv2 get-account --region us-east-1`
2. Inspect API logs for verification send failures:
   - `journalctl -u fjcloud-api --since "10 minutes ago" | grep -i "failed to send verification email"`
   - Log source owner: `routes/auth.rs` (`send_verification_email`).
3. Check SES suppression list for affected recipient.
4. Verify `SES_FROM_ADDRESS` identity/domain is verified and healthy.

## Decision flow
- SES sandbox limit/root-cause confirmed:
  - Request/confirm SES production access path per email runbook.
- Single-customer issue only:
  - Validate suppression status, clear if appropriate, then use
    `/auth/resend-verification`.
- SES/provider outage or broad send failures:
  - Check provider status page, communicate impact, wait/retry when stable.

## Response actions
1. Capture recipient, timestamp, signup attempt ID, and SES/account state.
2. For isolated suppression cases, remediate recipient path and retry send.
3. For systemic SES issues, publish incident status and monitor recovery.
4. Confirm verification email delivery and successful account verification.

## Response time
Severity ownership and response-time targets are defined in
`docs/runbooks/incident-response.md`. Do not create a second severity rubric
in this card.

## Deep-dive references
- `docs/runbooks/email-production.md`
- `docs/runbooks/incident-response.md`
- `docs/runbooks/alerting.md`
