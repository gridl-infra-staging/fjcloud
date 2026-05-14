# Browser-lane staging evidence — 20260505T065807Z

- **Lane:** both
- **Git SHA:** 248c34619e973aeec91d77d7c4f32465631c2286
- **BASE_URL:** https://cloud.flapjack.foo
- **API_URL:** https://api.flapjack.foo
- **PLAYWRIGHT_TARGET_REMOTE:** 1
- **Started at (UTC):** 20260505T065807Z

Run by `scripts/launch/run_browser_lane_against_staging.sh`. See
`signup_to_paid_invoice.txt` and/or
`billing_portal_payment_method_update.txt` for per-spec stdout.
Playwright artifacts under
`web/test-results/` and `web/playwright-report/` are NOT copied here
by default — the operator should run `cp -r web/test-results <bundle>`
after the run if needed for failure diagnosis.

## Verdict: RED

- LB-2 passed: 1
- LB-2 failed: 0
- LB-3 passed: 0
- LB-3 failed: 1
- Deployed staging SHA: 5a57ea6a280a1d63b54957b3732dcf8cc0a08c2e
- Bundle path: docs/runbooks/evidence/browser-evidence/20260505T065807Z_current_main

### LB-3 Failure Summary

`billing_portal_payment_method_update.spec.ts:32` — `getByRole('heading', { name: 'Payment methods' })` not found.
The deployed staging billing page renders the legacy Stripe portal redirect
("Use Stripe Customer Portal..." + "Manage billing" button) instead of the
in-app payment method management UI. See `stage4_gap_spec.md` for root cause
analysis and smallest hypothesized fix.
