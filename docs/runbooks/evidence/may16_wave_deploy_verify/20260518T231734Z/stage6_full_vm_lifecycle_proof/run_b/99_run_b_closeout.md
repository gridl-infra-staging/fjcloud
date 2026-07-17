# Run-B Closeout (Stage 6, Deferred - External PM Blocker)

Execution artifacts (latest root attempt):
- `run_b.stdout`
- `run_b.stderr`
- `run_b.exit`

Attempt history (new in this session):
- `attempt_6_20260519T042312Z`: index/search path succeeded; PM attach failed with HTTP 400.
- `attempt_7_20260519T042512Z`: failed at create_index HTTP 504.
- `attempt_8_20260519T042942Z`: index retry succeeded; PM attach failed with HTTP 400.
- `attempt_9_20260519T043150Z`: `pm_card_visa` trial still failed at PM attach.
- `attempt_10_20260519T043340Z`: PM attach failure now emits Stripe detail (`No such customer`) via helper diagnostics.
- `attempt_11_20260519T043617Z`: owner retry logic hit 3x transient 504 and failed create_index after retries.
- `attempt_12_20260519T044027Z`: index retry recovered; run-b blocked by live-key cutover guard.
- `attempt_13_20260519T044220Z`: with `STRIPE_LIVE_CUTOVER=1`, `pm_card_visa` rejected in livemode.
- `attempt_14_20260519T044324Z`: with secret-provided PM id + live cutover, Stripe returned `No such PaymentMethod`.

Owner-seam fixes landed this session:
- Added transient create-index retries (502/503/504) in `run_index_create_step`.
- Guarded pre/post cleanup invoice SQL capture when invoice id is empty and removed stale invoice SQL/error artifacts when skipped.
- Added Stripe payment-method error detail propagation (parsed error + request-id context).
- Updated run-b Stripe key selection to prefer `STRIPE_SECRET_KEY_flapjack_cloud` (account alignment with prod customer sync).

Current blocker summary:
- PM-backed path remains blocked by external live Stripe instrument availability:
  - test fixture PM ids are invalid in livemode (`attempt_13_.../run_b.stdout`)
  - secret-provided PM id is not present in the live account (`attempt_14_.../run_b.stdout`)
- Because attach fails before invoice finalize, root `run_b/` still lacks `metadata.json`, `stripe_paid_state.json`, and raw pre-cleanup DB paid-state artifacts.

Operational note:
- Latest root `run_b.stdout` may represent any final probe attempt; use attempt directories above for stable forensic references.
