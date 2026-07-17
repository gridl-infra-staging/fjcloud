# Browser-lane staging evidence — 20260518T032358Z

- **Lane:** signup_to_paid_invoice
- **Git SHA:** 0ea99e1e01c662595efb49b754f0fa008d8d9c2b
- **BASE_URL:** https://cloud.flapjack.foo
- **API_URL:** https://api.staging.flapjack.foo
- **PLAYWRIGHT_TARGET_REMOTE:** 1
- **Started at (UTC):** 20260518T032358Z

Run by `scripts/launch/run_browser_lane_against_staging.sh`. See
`signup_to_paid_invoice.txt` and/or
`billing_portal_payment_method_update.txt` for per-spec stdout.
Playwright artifacts under
`web/test-results/` and `web/playwright-report/` are NOT copied here
by default — the operator should run `cp -r web/test-results <bundle>`
after the run if needed for failure diagnosis.
