# Stage 4 Gap Spec — LB-3 billing_portal_payment_method_update RED

## Failing Test

- **Spec:** `web/tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts:32`
- **Assertion:** `await expect(page.getByRole('heading', { name: 'Payment methods' })).toBeVisible()`
- **Timeout:** 5000ms
- **Error:** element(s) not found

## Observed Page State (from Playwright error-context snapshot)

The deployed staging billing page at `https://cloud.flapjack.foo/dashboard/billing` renders:
- `heading "Billing" [level=1]` (visible — assertion at line 31 passes)
- `paragraph: "Use Stripe Customer Portal to manage payment methods and subscription billing details."`
- `button "Manage billing"` (portal redirect form)

This is the **legacy portal-redirect billing UI**, NOT the in-app payment method
management UI that the spec expects.

## Expected Page State (from spec + current main code)

The billing page on current main (`web/src/routes/dashboard/billing/+page.svelte`)
renders when `billingUnavailable` is false:
- `h1 "Billing"`
- `h2 "Payment methods"` (the heading the spec expects)
- Payment method list with set-default forms
- `PaymentMethodSetupForm` (Stripe Elements card entry)

When `billingUnavailable` is true, it renders `BillingUnavailableCard`:
- `"Payment method management unavailable"` + `"Stripe is not available in this environment."`

Neither path renders "Use Stripe Customer Portal..." or "Manage billing" — that
content was the pre-rewrite page structure (removed in commits `68c285ea` May 1 and
`69c5fea0` May 4 on dev-repo main).

## Root Cause Hypothesis

The deployed staging web frontend (SHA `5a57ea6a` in `gridl-infra-staging/fjcloud`)
does NOT include the billing page rewrite that landed on dev-repo main on 2026-05-01
(`68c285ea`) and 2026-05-04 (`69c5fea0`). The deployed code still has the legacy
portal redirect form and "Use Stripe Customer Portal" copy.

Most likely cause: the staging deploy artifact (SvelteKit build served by the staging
host) was built from an earlier sync that predates these billing page commits, OR the
latest debbie sync completed the git push to the staging repo but the CI deploy job
has not rebuilt/redeployed the web frontend since.

## Smallest Hypothesized Fix

1. Verify the staging repo at `5a57ea6a` actually contains the billing page rewrite:
   ```bash
   cd /Users/stuart/repos/gridl-infra-staging/fjcloud
   git show 5a57ea6a:web/src/routes/dashboard/billing/+page.svelte | head -20
   ```
2. If the file is stale: re-run `debbie sync staging` to push current main state, then
   trigger the staging CI `deploy-staging` workflow to rebuild and deploy the web frontend.
3. If the file is current but the deploy artifact is stale: trigger a staging redeploy
   (`gh workflow run deploy-staging.yml -R gridl-infra-staging/fjcloud`) without a new sync.
4. Re-run this stage's browser lane invocation after redeploy confirms the new frontend is live.

## Evidence Preserved

- `billing_portal_payment_method_update.txt` — full Playwright stdout with failure trace
- `web/test-results/e2e-ui-full-billing_portal-8de8c-d-keeps-billing-page-stable-chromium/test-failed-1.png` — screenshot
- `web/test-results/e2e-ui-full-billing_portal-8de8c-d-keeps-billing-page-stable-chromium/error-context.md` — accessibility tree snapshot
