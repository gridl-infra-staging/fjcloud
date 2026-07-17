# Billing Coverage A2 Live Stripe Clock Closure

- Timestamp (UTC): 2026-05-25T21:40:14Z
- Bundle path: `docs/runbooks/evidence/billing_coverage_a2/20260525T214014Z_LIVE/`
- Scope: close the last A2 non-live row by rerunning the nightly Stripe test-clock owner against the real Stripe sandbox.

## Prerequisites used for the live rerun

- Secret source: `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`
- Explicit env overrides for this owner:
  - `STRIPE_PRICE_STARTER=price_1TSPKBGXI8zVz4UH153cTXuz`
  - `STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS=500`
  - `INTEGRATION=1`
  - `BACKEND_LIVE_GATE=1`
- `prereq_env_status.log` captures the exact values surfaced to the test process.

## Command outcomes

- `bash scripts/tests/nightly_workflow_test.sh`
  - PASS
  - Evidence: `01.log`
- `cd infra && cargo test -p api --test stripe_test_clock_full_cycle_test -- --nocapture`
  - PASS
  - Evidence: `02.log`

## What changed to make the owner deterministic

The first live rerun exposed a real test-owner defect: `stripe_test_clock_full_cycle_test.rs` only locked shared env reads for precondition checks, while helper tests in `api/tests/common/live_stripe_helpers.rs` mutated `STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS` and left it at `900`. That leaked into the live owner and produced a false expected amount. This closure holds the env lock for the full live test and restores the helper-test env mutations, so the owner now reads the intended `500`-cent contract value deterministically.

## Publication contract

- Section 2 in `docs/launch_verification_matrix.md` can now move from `pending` to `live`.
- The hand-calculated Stripe test-clock row now terminates at `02.log` in this bundle.
- The remaining Section 2 rows continue to point at `docs/runbooks/evidence/billing_coverage_a2/20260525T212954Z_GREEN/`, which is still fresh and remains the row owner for the non-clock coverage.
