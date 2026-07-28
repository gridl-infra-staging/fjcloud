# Browser-lane LOCAL evidence — 20260728T183201Z

- **Lane:** upgrade_to_shared_unmocked
- **Git SHA:** 74091fba7e5462694b8c8bd7273016cb08063655
- **Target:** LOCAL stack, REAL Stripe test mode
- **BASE_URL (web):** http://localhost:5273
- **API_URL:** http://127.0.0.1:3051
- **FLAPJACK_URL:** http://127.0.0.1:7751
- **Stripe publishable prefix:** pk_test_…
- **PLAYWRIGHT_TARGET_REMOTE:** (unset — local auto-verify)
- **Started at (UTC):** 20260728T183201Z

Run by `scripts/launch/run_browser_lane_locally.sh`. Per-spec stdout lives in
`signup_to_paid_invoice.txt` / `billing_portal_payment_method_update.txt` /
`upgrade_to_shared_unmocked.txt` (each ends with an `exit=<code>` line). This is the FAST local lane;
`run_browser_lane_against_staging.sh` remains the deploy gate.
