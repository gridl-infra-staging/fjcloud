# Browser-lane staging evidence — 20260805T143632Z

- **Lane:** signup_to_paid_invoice
- **Git SHA:** 957e2124cc86e48da5ff1829d195d85bcff2d5a1
- **BASE_URL:** https://cloud.staging.flapjack.foo
- **API_URL:** https://api.staging.flapjack.foo
- **PLAYWRIGHT_TARGET_REMOTE:** 1
- **Started at (UTC):** 20260805T143632Z

Run by `scripts/launch/run_browser_lane_against_staging.sh`. See
`signup_to_paid_invoice.txt` and/or
`billing_portal_payment_method_update.txt` for per-spec stdout.
Launcher-owned trace artifacts are copied to
`playwright-traces/` in this bundle. See
`trace_copy_summary.json` for machine-readable copy status,
source directories inspected, and copied file count.

Post-review public-evidence correction (2026-08-05): the copied `trace.zip`
contained authentication material and was removed in a forward correction. The
per-spec stdout remains the acceptance result; the original archive-aware,
redacted finding report is retained under `docs/live-state/20260805T142708Z/`.
