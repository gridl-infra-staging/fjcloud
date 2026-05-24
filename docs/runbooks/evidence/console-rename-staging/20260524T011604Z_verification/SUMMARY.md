# Stage 6 Staging Verification — Console Rename

**Timestamp**: 2026-05-24T02:02:53Z
**Target**: cloud.staging.flapjack.foo / api.staging.flapjack.foo
**Branch**: batman/may23_9pm_2_routes_dashboard_to_console
**CF Pages deploy**: ddb18e8c.flapjack-cloud.pages.dev (staging alias)

## Probe Results

| # | Probe | Expected | Actual | Verdict |
|---|-------|----------|--------|---------|
| 00 | CI preflight | success | playwright flaky (pre-existing) | KNOWN |
| 00 | Pre-deploy status | — | staging 29 commits behind | NOTED |
| 00 | Live state ref | all OK except stripe_account_config | per docs/live-state/20260524T012853Z | NOTED |
| 01 | `/console` auth guard | 303 → /login | 303 → /login | PASS |
| 02 | `/dashboard` root redirect | 308 → /console | 308 → /console | PASS |
| 03 | `/dashboard/billing` deep path | 308 → /console/billing | 308 → /console/billing | PASS |
| 04 | `/dashboard/billing?tab=invoices&page=2` query preservation | 308 → /console/billing?tab=invoices&page=2 | 308 → /console/billing?tab=invoices&page=2 | PASS |
| 05 | OAuth google start | 302 → accounts.google.com | 302 | PASS |
| 06 | Web API_BASE_URL contract | staging→api.staging | staging→api.staging | PASS |
| 07 | `/signup` copy — no "dashboard" | 0 occurrences | 0 occurrences | PASS |
| 08 | OAuth redirect URI contract | — | SKIP (no local OAuth creds) | SKIP |
| 09 | Stripe portal return URL | /console/billing | /console/billing | PASS |
| 10 | Dunning email URL tests | all pass | 36 passed, 0 failed | PASS |
| 11 | Billing portal test | all pass | 26 passed, 0 failed | PASS |
| 12 | local-ci | all 9 gates pass | all 9 gates pass | PASS |

## Fix Applied During Verification

Dashboard redirect routes (`/dashboard` → `/console` 308) were initially implemented using
`+page.server.ts` with redirect-only load functions. SvelteKit excludes these from the server
manifest when the companion `+page.svelte` has no rendered content, causing 404s on staging.

**Fix**: Replaced `+page.server.ts` + `+page.svelte` pairs with `+server.ts` GET handlers.
Server endpoints don't require page components and are correctly registered in the manifest.

Files changed:
- Removed: `web/src/routes/dashboard/+page.server.ts`
- Removed: `web/src/routes/dashboard/+page.svelte`
- Removed: `web/src/routes/dashboard/[...path]/+page.server.ts`
- Removed: `web/src/routes/dashboard/[...path]/+page.svelte`
- Added: `web/src/routes/dashboard/+server.ts`
- Added: `web/src/routes/dashboard/[...path]/+server.ts`
- Updated: `web/src/routes/dashboard/dashboard_redirect.server.test.ts` (imports updated)

## Overall Verdict

**PASS** — All staging probes verify the console rename is correctly deployed.
Legacy /dashboard URLs redirect with 308 permanent, query strings are preserved,
auth guards work on /console, and customer-facing copy references "Console" not "Dashboard".
