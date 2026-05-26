# Billing Coverage A2 Evidence Bundle

- Timestamp (UTC): 2026-05-25T21:29:54Z
- Bundle path: `docs/runbooks/evidence/billing_coverage_a2/20260525T212954Z_GREEN/`
- Scope: Section 2 owner-backed coverage reruns for launch matrix publication.

## Prerequisite gate outcome (live Stripe lane)

Live Stripe prerequisites required by `.github/workflows/nightly.yml` and `infra/api/tests/stripe_test_clock_full_cycle_test.rs` were **not present in this environment**.

- Required env vars status (`prereq_env_status.log`):
  - `STRIPE_SECRET_KEY`: unset
  - `STRIPE_WEBHOOK_SECRET`: unset
  - `STRIPE_PRICE_STARTER`: unset
  - `STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS`: unset
  - `INTEGRATION`: unset
  - `BACKEND_LIVE_GATE`: unset
  - `INTEGRATION_API_BASE`: unset
  - `INTEGRATION_DB_URL`: unset

Because prerequisites are missing, Section 2 remains `pending` and the Stripe test-clock row is marked non-live.

## Row-to-owner mapping (published rows must terminate here)

- Hand-calculated Stripe test-clock billing amount owner:
  - `infra/api/tests/stripe_test_clock_full_cycle_test.rs:24`
  - Evidence logs: `02.log` (command executes but live preconditions skip)
- Metering-to-invoice + midnight UTC boundary owners:
  - `infra/api/tests/integration_metering_pipeline_test.rs:365`
  - `infra/api/tests/integration_metering_pipeline_test.rs:409`
  - Evidence logs: `03.log`, `04.log`
- Webhook signature owners:
  - `infra/api/tests/stripe_webhook_signature_test.rs:42`
  - `infra/api/tests/stripe_webhook_signature_test.rs:83`
  - `infra/api/tests/stripe_webhook_signature_test.rs:107`
  - Evidence log: `05.log`
- Webhook idempotency owners:
  - `infra/api/tests/stripe_webhook_idempotency_test.rs:41`
  - `infra/api/tests/stripe_webhook_idempotency_test.rs:196`
  - `infra/api/tests/stripe_webhook_idempotency_test.rs:403`
  - Evidence log: `07.log`
- Refund-state reversion owner:
  - `infra/api/tests/stripe_webhook_event_matrix_test.rs:199` (`charge_refunded_marks_paid_invoice_refunded`)
  - Evidence log: `06.log`
- Declined-card / dunning owner:
  - Canonical owner test: `infra/api/tests/integration_stripe_test.rs:1158`
  - Checklist command `webhook_dunning_email_test ... stripe_payment_failure_webhook_fires_on_declined_card` filtered out all tests (`08.log`); corrected owner rerun: `12_corrected_dunning_command.log`
- Pricing / cross-region math owners:
  - `infra/api/tests/billing_regression_test.rs:744`
  - `infra/api/tests/billing_regression_test.rs:1036`
  - `infra/api/tests/billing_regression_test.rs:1066`
  - `infra/api/tests/invoicing_compute_test.rs:80`
  - `infra/api/tests/invoicing_compute_test.rs:138`
  - `infra/api/tests/invoicing_compute_test.rs:193`
  - Evidence logs: `09.log`, `10.log`, `11.log`
- SCA / upgrade ambiguity resolution owners:
  - `infra/api/tests/billing_endpoints_test.rs:3854`
  - `infra/api/tests/stripe_pay_invoice_test.rs:85`
  - Legacy lifecycle boundary owner (do not overclaim downgrade/cancel):
  - `infra/api/tests/billing_endpoints_test.rs:4645`

## Command outcomes

All executed commands returned exit code 0. See `results.json` for full command list and pass/fail status.

- Nightly contract: `01.log`
- Stripe test clock targeted run: `02.log`
- Metering targeted runs: `03.log`, `04.log`
- Signature/idempotency/event matrix: `05.log`, `06.log`, `07.log`
- Dunning target correction: `12_corrected_dunning_command.log`
- Pricing/rate-card/invoicing targeted runs: `09.log`, `10.log`, `11.log`
