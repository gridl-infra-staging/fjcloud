# Browser Evidence Summary

- Capture timestamp (UTC): 2026-04-28T20:25:44Z
- Git SHA: ba37986d3d58c733c94af05714661c8bfa15b889
- Playwright version: Version 1.58.2
- Executed projects: chromium, chromium:signup

## Spec Results
- tests/e2e-ui/full/signup_to_paid_invoice.spec.ts: failed (fixture precondition: no stripe price configured for plan: starter)
- tests/e2e-ui/full/billing_portal_cancel.spec.ts: failed (fixture precondition: no stripe price configured for plan: starter)

## Retained artifacts
- HTML report: playwright-report/index.html
- JSON report: report.json
- Test output root: test-results/
- Signup failure screenshot: test-results/e2e-ui-full-signup_to_paid-43e41-aches-paid-invoice-evidence-chromium-signup/test-failed-1.png
- Signup error context: test-results/e2e-ui-full-signup_to_paid-43e41-aches-paid-invoice-evidence-chromium-signup/error-context.md
- Billing portal failure screenshot: test-results/e2e-ui-full-billing_portal-ffbff-r-owned-cancellation-banner-chromium/test-failed-1.png
- API log: api-dev.log
