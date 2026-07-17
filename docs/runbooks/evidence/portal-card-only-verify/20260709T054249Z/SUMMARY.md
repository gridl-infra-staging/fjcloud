# Portal Card-Only Payment Element Verification

## (a) Card-Only Root Cause

The SetupIntent created by `LiveStripeService::create_setup_intent` in
`infra/api/src/stripe/live.rs:246` explicitly sets `payment_method_types = Some(vec!["card".to_string()])`.
This restricts the Stripe Payment Element to card-only entry. The browser helper
`selectStripeCardMethodWhenPresent` in the spec exists to handle this constraint.

## (b) Stage 1 Baseline Classification

FAIL. The Stage 1 baseline run (`/tmp/portal_run_baseline.txt`) failed because the local
`webServer` served a mismatched publishable key (pk_live_ from `.env.local` while the secret
key was sk_test_), causing the Stripe Payment Element to refuse to mount (publishable-key
503 / mode mismatch).

## (c) Stage 2 Code Changes

None. HEAD remained at `dc8ae8bd` with a clean git tree throughout Stage 2. The Stage 1
FAIL was an environment precondition issue (publishable-key mode mismatch), not a defect in
`selectStripeCardMethodWhenPresent` or any product/test code. Stage 2 reproduced green by
running via `scripts/launch/run_browser_lane_locally.sh` which hydrates matching
`pk_test_`/`sk_test_` keys from SSM.

## (d) Final Playwright Pass Line

```
  2 passed (38.0s)
```

Both tests passed:
- `spec.ts:127` — in-app default PM switch (17.4s)
- `spec.ts:212` — @p0_coverage save via Stripe Payment Element (14.4s)

## (e) End-Effect Assertions

The spec proves default-payment-method behavior via `waitForStripeDefaultPaymentMethod`,
which polls the Stripe API until the customer's default PM matches the expected value:

- `spec.ts:205-209`: After the in-app default-PM switch,
  `waitForStripeDefaultPaymentMethod(stripeCustomerId, expectedDefaultPaymentMethodId)`
  returns the new default, and `expect(currentDefaultPaymentMethodId).toBe(arrangedCustomer.expectedDefaultPaymentMethodId)` confirms the Stripe-side mutation landed.

- `spec.ts:284-288`: After saving a new card via the Stripe Payment Element,
  `waitForStripeDefaultPaymentMethod(stripeCustomerId, defaultPaymentMethodId)`
  confirms the original default PM is preserved (Stripe does not auto-promote SetupIntent PMs),
  and `expect(defaultPaymentMethodId).toBe(arrangedCustomer.defaultPaymentMethodId)` asserts this.
