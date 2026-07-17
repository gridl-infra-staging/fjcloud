# Stage 4 Gap Spec — LB-2 signup_to_paid_invoice RED (API Logs heading)

## Failing Test

- **Spec:** `web/tests/e2e-ui/full/signup_to_paid_invoice.spec.ts:78`
- **Assertion:** `await expect(page.getByRole('heading', { name: 'API Logs' })).toBeVisible({ timeout: 15_000 })` (inside `assertDashboardRouteWalk`, line 42)
- **Timeout:** 15000ms
- **Error:** element(s) not found

## Context

This is the second browser-lane run for Stage 4. The first run
(20260505T065807Z) had LB-2 GREEN — the route walk including
`/dashboard/logs` passed against the OLD Cloudflare Pages deployment.
After redeploying the web frontend to fix the LB-3 stale-page failure,
LB-2 now fails.

The only change between the two runs is the Cloudflare Pages
deployment: the new build includes all code synced to staging via
debbie (notably the billing page rewrite from commits `68c285ea` and
`69c5fea0`).

## Observed Behavior

The test progresses through signup, email verification, re-login, and
begins the dashboard route walk. The first four routes pass:

1. `/dashboard` — heading "Dashboard" visible
2. `/dashboard/indexes` — heading "Indexes" visible
3. `/dashboard/billing` — heading "Billing" visible
4. `/dashboard/api-keys` — heading "API Keys" visible

Route 5 (`/dashboard/logs` — heading "API Logs") fails: element not
found after 15 seconds. The heading is completely absent from the DOM,
not merely hidden.

## Expected Page State

`web/src/routes/dashboard/logs/+page.svelte` renders:
- `<h1 class="mb-6 text-2xl font-bold text-gray-900">API Logs</h1>`
- `<ApiLogViewer />` (client-side component, no server load)

The page has no `+page.server.ts` or `+page.ts`. The `ApiLogViewer`
component reads from a browser-only session-storage store. The build
includes the page: node chunk `27.CK-sHqBv.js` contains the "API Logs"
heading text.

## Root Cause Hypothesis

The billing page (route 3 in the walk) now loads
`PaymentMethodSetupForm`, which triggers `getStripe()` on mount.
`getStripe()` calls `loadStripe(publishableKey)` from `@stripe/stripe-js`,
which injects a `<script src="https://js.stripe.com/v3/">` tag. If
Stripe.js loading triggers an uncaught client-side error (or
interferes with SvelteKit's client-side router), subsequent
navigations may fail to render page components.

Supporting evidence:
- LB-2 passed in the first run when the billing page rendered the
  legacy portal-redirect UI (no Stripe.js loading)
- LB-2 fails in the second run where the billing page loads Stripe.js
  via `PaymentMethodSetupForm`
- The LB-3 test confirms Stripe Elements is NOT rendering (payment-element
  div exists but is hidden/empty), suggesting `getStripe()` or
  `loadStripe()` is failing

The logs page test-results directory (screenshot + error-context.md)
was overwritten by the subsequent LB-3 Playwright run and is not
available for this bundle.

## Smallest Hypothesized Fix

1. Verify Stripe.js loading behavior on the deployed billing page by
   checking browser console for errors:
   ```bash
   # In a browser dev console at cloud.flapjack.foo/dashboard/billing:
   # Check for Stripe.js errors, CSP violations, or fetch failures
   ```
2. If `getStripe()` fails: check that the Worker environment serves
   `/api/stripe/publishable-key` correctly to authenticated users
3. If Stripe.js CDN loading is the issue: may need to pre-load or
   handle the failure more gracefully to avoid side effects on
   SvelteKit's client-side router
4. After fixing, re-run both lanes

## Evidence Preserved

- `signup_to_paid_invoice.txt` — full Playwright stdout with failure trace
- LB-2 screenshot and error-context.md were NOT preserved (overwritten
  by subsequent LB-3 Playwright run)
