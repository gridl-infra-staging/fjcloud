# Browser Evidence Summary

- Capture timestamp (UTC): 2026-04-29T16:54:50Z
- Result: failed before assertions (signup fixture precondition)
- Failure owner handback: Stage 2
- Failure directory: 20260429T164954Z_current_main

## Spec Results
- tests/e2e-ui/full/signup_to_paid_invoice.spec.ts: failed (arrangePaidInvoiceForFreshSignup failed to sync stripe customer: 500)
- tests/e2e-ui/full/billing_portal_cancel.spec.ts: not run (stopped after first target failure per Stage 3 checklist)

## API evidence
- /admin/customers/:id/sync-stripe returned 500
- Underlying Stripe error from API logs: invalid_request_error (401) Invalid API Key provided

## Retained artifacts
- HTML report: playwright-report/index.html
- Test output root: test-results/
- API log: api-dev.log
- Stripe key fingerprint: stripe_key_fingerprint.txt (redacted hash only)
