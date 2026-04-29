# Stage 3 Cross-Check Computation Companion

This file is an operator-readable companion to `cross_check_result.json`.
`cross_check_result.json` remains the machine-readable verdict SSOT.

## Known-Answer Outcome (Stage 2 Proof Owner)

- Invoice: `e7806ad2-977d-4f4b-9ff9-95c7ddab49e3`
- Canonical proof test: `infra/api/tests/billing_regression_test.rs::shared_plan_staging_bundle_known_answer_regression`
- Proven generated values: `subtotal_cents=11`, `total_cents=500`, `minimum_applied=true`
- Persisted DB values (`invoice_db_row.json`): `subtotal_cents=11`, `total_cents=500`, `minimum_applied=true`
- Verdict token (`cross_check_result.json`): `CROSS_CHECK_PASSED`

## One-Line-Item Replay Basis

- `invoice_line_items.json` contains exactly one row for this invoice:
  `description="Hot storage (us-east-1)"`, `quantity=2.294349`, `unit_price_cents=5.0000`, `amount_cents=11`.
- The shared-plan minimum floor then yields `total_cents=500` with `minimum_applied=true` per the Stage 2 canonical test above.
- `usage_daily_replay_rows.json` is bounded at `invoice_created_at`, and `usage_records_provenance.json` is bounded to raw rows whose UTC day/region keys match those captured replay rows and whose `recorded_at` does not exceed the matching replay row `aggregated_at` cutoff or `invoice_created_at`.

## Source Artifacts

- `cross_check_result.json`
- `invoice_db_row.json`
- `invoice_line_items.json`
- `customer_billing_context.json`
- `rate_card_selection.json`
- `customer_rate_override.json`
- `usage_daily_replay_rows.json`
- `usage_records_provenance.json`
