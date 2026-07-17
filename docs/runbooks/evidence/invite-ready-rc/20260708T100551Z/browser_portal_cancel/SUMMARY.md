# Browser-lane staging evidence — 20260708T101523Z

- **Lane:** billing_portal_payment_method_update
- **Git SHA:** a4d1d3dc2d118e3d06790408bf2bc27bd706e65d
- **BASE_URL:** https://cloud.staging.flapjack.foo
- **API_URL:** https://api.staging.flapjack.foo
- **PLAYWRIGHT_TARGET_REMOTE:** 1
- **Started at (UTC):** 20260708T101523Z

Run by `scripts/launch/run_browser_lane_against_staging.sh`. See
`signup_to_paid_invoice.txt` and/or
`billing_portal_payment_method_update.txt` for per-spec stdout.
Launcher-owned trace artifacts are copied to
`playwright-traces/` in this bundle. See
`trace_copy_summary.json` for machine-readable copy status,
source directories inspected, and copied file count.

Sensitive note: the failing `trace.zip` archive for this lane was removed from
the committed bundle during posthoc security review because the raw Playwright
trace captured authenticated cookies and plaintext test credentials.
