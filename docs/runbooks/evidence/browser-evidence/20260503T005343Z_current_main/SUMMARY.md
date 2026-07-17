# Browser-lane staging evidence — 20260503T005343Z

- **Lane:** signup_to_paid_invoice
- **Git SHA:** ab2ade9cbe4c17762e44a7da38dea0c4cd89198a
- **BASE_URL:** https://cloud.flapjack.foo
- **API_URL:** https://api.flapjack.foo
- **PLAYWRIGHT_TARGET_REMOTE:** 1
- **Started at (UTC):** 20260503T005343Z

Run by `scripts/launch/run_browser_lane_against_staging.sh`. See
`signup_to_paid_invoice.txt` and/or
`billing_portal_payment_method_update.txt` for per-spec stdout.
Playwright artifacts under
`web/test-results/` and `web/playwright-report/` are NOT copied here
by default — the operator should run `cp -r web/test-results <bundle>`
after the run if needed for failure diagnosis.
