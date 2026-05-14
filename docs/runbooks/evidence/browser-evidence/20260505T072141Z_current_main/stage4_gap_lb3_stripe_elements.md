# Stage 4 Gap Spec — LB-3 billing_portal_payment_method_update RED (Stripe Elements hidden)

## Failing Test

- **Spec:** `web/tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts:22`
- **Assertion:** `await expect(page.getByTestId('payment-element')).toBeVisible()` (line 42)
- **Timeout:** 5000ms (Playwright default)
- **Error:** locator resolved to element but it was hidden

## Progress from Prior Run

The first Stage 4 run (20260505T065807Z) failed at line 32: the
deployed billing page still had the legacy portal-redirect UI. After
redeploying the web frontend via Cloudflare Pages Direct Upload, the
billing page now renders the correct in-app UI:

- `heading "Billing"` visible ✓
- `heading "Payment methods"` visible ✓ (line 32 passes)
- Two payment method cards listed (Mastercard 4444, Visa 4242) ✓
- `button "Manage billing"` absent ✓ (line 33 passes)
- `heading "Add or update card"` visible ✓
- `button "Save payment method"` visible ✓

## Observed Failure

The `payment-element` div exists on the page with correct
`data-testid` and a valid setup-intent ID in its `id` attribute:
```
<div class="mb-6" data-testid="payment-element"
     id="payment-element-seti-1TTdJ5KH9mdklKeIfaktfaRY-secret-USYP0IcBSQIEViSUG4etYeJci42jUTW">
</div>
```

Playwright resolved the locator 9 times, each time finding the element
hidden (zero-height empty div). Stripe.js did NOT mount a payment
element iframe inside the container.

## Root Cause Hypothesis

The `PaymentMethodSetupForm` component receives `clientSecret` as a
prop (confirmed: the setup intent secret is in the element's `id`).
On mount, it calls `getStripe()`, which:

1. Fetches `/api/stripe/publishable-key` (server route at
   `web/src/routes/api/stripe/publishable-key/+server.ts`)
2. The server route calls `getApiBaseUrl() + /billing/publishable-key`
   (API_BASE_URL = `https://api.flapjack.foo` per wrangler.toml)
3. Returns the publishable key to the browser
4. Calls `loadStripe(publishableKey)` from `@stripe/stripe-js`
5. On success, creates Elements + mounts payment element

If any step fails, `getStripe()` returns null (caught by try/catch),
and `remountPaymentElement` returns early without mounting. The div
remains empty = zero height = hidden.

Most likely failure point:
- **Step 1**: The fetch to `/api/stripe/publishable-key` succeeds
  (the route is verified accessible, returns 401 for unauthed, should
  work for authed users via the auth cookie)
- **Step 4**: `loadStripe()` injects `<script src="js.stripe.com/v3/">`
  which may fail or timeout in the headless Chromium test environment.
  If Stripe.js can't load (network, DNS, or CSP), `loadStripe` rejects,
  the catch returns null, and the element stays empty.

The LB-2 failure at `/dashboard/logs` after visiting the billing page
supports this hypothesis: if Stripe.js loading fails with a side
effect that breaks SvelteKit's client-side router, it would explain
both failures in a single root cause.

## Evidence Preserved

- `billing_portal_payment_method_update.txt` — full Playwright stdout
- `web/test-results/e2e-ui-full-billing_portal-8de8c-d-keeps-billing-page-stable-chromium/test-failed-1.png` — screenshot (shows correct billing UI, empty Stripe Elements area)
- `web/test-results/e2e-ui-full-billing_portal-8de8c-d-keeps-billing-page-stable-chromium/error-context.md` — full accessibility tree snapshot

## Smallest Hypothesized Fix

1. Verify `getStripe()` behavior on deployed staging: authenticate as a
   test user and check browser console for fetch errors or Stripe.js
   loading failures at `/dashboard/billing`
2. If Stripe.js CDN loading fails in the test environment:
   - Check if headless Chromium can reach `js.stripe.com`
   - Check for DNS resolution issues from the test runner's network
3. If `/api/stripe/publishable-key` returns an error for the test user:
   - Check Cloudflare Worker logs for errors on that route
   - Verify the API backend returns the publishable key for the test
     user's auth token
4. After fixing, re-run both lanes
