# Browser-lane staging evidence — 20260502T042414Z

- **Lane:** both
- **Git SHA:** fffc191d2658848a6efc7fc94320609dfaf0e2e2
- **BASE_URL:** https://cloud.flapjack.foo
- **API_URL:** https://api.flapjack.foo
- **PLAYWRIGHT_TARGET_REMOTE:** 1
- **Started at (UTC):** 20260502T042414Z

Run by `scripts/launch/run_browser_lane_against_staging.sh`. See
`signup_to_paid_invoice.txt` and/or `billing_portal_cancel.txt` for
per-spec stdout. Playwright artifacts under
`web/test-results/` and `web/playwright-report/` are NOT copied here
by default — the operator should run `cp -r web/test-results <bundle>`
after the run if needed for failure diagnosis.
