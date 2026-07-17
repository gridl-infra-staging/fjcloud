# Payment Failure — Operator One-Pager

## Trigger symptoms
- Critical alert: AlertService reports "Customer suspended".
- Stripe webhook events include `payment_intent.payment_failed`.
- Support reports recent paid customer lockouts after renewal attempt.

## Immediate checks (first 5 minutes)
1. Identify impacted tenant/customer ID from alert payload.
2. In Stripe Dashboard, open latest failed payment and record decline code.
3. Query admin APIs:
   - `GET /admin/alerts` for matching alert timeline.
   - `GET /admin/tenants/<id>` for tenant billing/suspension state.
4. Confirm whether retries are exhausted versus transient first-attempt failure.

## Decision flow
- Single customer failure:
  - Follow customer contact steps in
    `docs/runbooks/customer-suspension.md` (Contacting section).
  - Confirm whether manual retry or payment method update resolves issue.
- Multiple customers failing in same window:
  - Check Stripe status page and processor incident reports.
  - Treat as systemic payment incident; coordinate status communications.
- False positive suspicion:
  - Verify webhook/event ordering and invoice state before unsuspending.

## Response actions
1. Preserve evidence: alert ID, tenant ID, Stripe payment intent, decline code.
2. If transient and retries not exhausted, monitor next retry window.
3. If retries exhausted, run customer-suspension recovery flow per runbook.
4. If systemic, announce degraded billing processing and monitor continuously.

## Response time
Severity level ownership and target response windows are defined only in
`docs/runbooks/incident-response.md`. Use that table as canonical and do not
apply card-local P1/P2 definitions.

## Deep-dive references
- `docs/runbooks/customer-suspension.md`
- `docs/runbooks/invoice-troubleshooting.md`
- `docs/runbooks/incident-response.md`
