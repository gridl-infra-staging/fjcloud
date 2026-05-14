# Browser-lane staging evidence — 20260505T072141Z

- **Lane:** both
- **Git SHA:** de0a929618a58142d7471358cd656d8dd617e444
- **BASE_URL:** https://cloud.flapjack.foo
- **API_URL:** https://api.flapjack.foo
- **PLAYWRIGHT_TARGET_REMOTE:** 1
- **Started at (UTC):** 20260505T072141Z

Run by `scripts/launch/run_browser_lane_against_staging.sh`. See
`signup_to_paid_invoice.txt` and/or
`billing_portal_payment_method_update.txt` for per-spec stdout.
Playwright artifacts under
`web/test-results/` and `web/playwright-report/` are NOT copied here
by default — the operator should run `cp -r web/test-results <bundle>`
after the run if needed for failure diagnosis.

## Verdict: RED

- LB-2 passed: 0
- LB-2 failed: 1
- LB-3 passed: 0
- LB-3 failed: 1
- Deployed staging SHA (Cloudflare Pages): ea89f398 (rebuilt from staging repo 9bada66)
- Bundle path: docs/runbooks/evidence/browser-evidence/20260505T072141Z_current_main

### Context

This is the second browser-lane run for Stage 4. The first run
(20260505T065807Z) failed only on LB-3 (stale Cloudflare Pages
deployment with legacy billing portal UI). After fixing the deployment
(debbie sync + staging repo commit/push + SvelteKit build + Cloudflare
Pages Direct Upload), LB-3 progresses further (billing page now
renders in-app UI) but fails on a different assertion: Stripe Elements
`payment-element` div exists but is hidden (empty, Stripe.js not
mounted).

LB-2, which passed in the first run, now fails: the dashboard route
walk finds `/dashboard/logs` does not render the "API Logs" heading.
This regression correlates with the new billing page loading Stripe.js
during the route walk.

### LB-2 Failure Summary

`signup_to_paid_invoice.spec.ts:42` — `getByRole('heading', { name: 'API Logs' })` not found
at `/dashboard/logs` during dashboard route walk. See
`stage4_gap_lb2_api_logs.md` for root cause analysis.

### LB-3 Failure Summary

`billing_portal_payment_method_update.spec.ts:42` — `getByTestId('payment-element')` resolved
but hidden (Stripe Elements not mounted). See
`stage4_gap_lb3_stripe_elements.md` for root cause analysis.
