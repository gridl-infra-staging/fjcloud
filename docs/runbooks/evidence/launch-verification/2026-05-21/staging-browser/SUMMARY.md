# Browser-lane staging evidence — 20260521T131053Z

- **Lane:** both
- **Git SHA:** 395271b1c609fb62439d73127289e6a8e4d61b0b
- **BASE_URL:** https://cloud.staging.flapjack.foo
- **API_URL:** https://api.staging.flapjack.foo
- **PLAYWRIGHT_TARGET_REMOTE:** 1
- **Started at (UTC):** 20260521T131053Z
- **Runner exit code:** 1
- **Overall verdict:** FAIL
- **signup_to_paid_invoice:** FAIL (`exit=1`; redirected to `/login?reason=session_expired` during dashboard route walk)
- **billing_portal_payment_method_update:** FAIL (`exit=1`; `/dashboard/billing` never rendered the expected `Billing` heading)

Run by `scripts/launch/run_browser_lane_against_staging.sh`. See
`signup_to_paid_invoice.txt` and/or
`billing_portal_payment_method_update.txt` for per-spec stdout.
This bundle is failed evidence only; it does not satisfy the Stage 2
launch-verification gate until both lane artifacts are re-run to
`exit=0`.
Playwright artifacts under
`web/test-results/` and `web/playwright-report/` are NOT copied here
by default — the operator should run `cp -r web/test-results <bundle>`
after the run if needed for failure diagnosis.
