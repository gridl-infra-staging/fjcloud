# Stage 7 Production Verification — Console Rename

**Timestamp**: 2026-05-24T02:31:21Z
**Target**: cloud.flapjack.foo / api.flapjack.foo
**Branch**: batman/may23_9pm_2_routes_dashboard_to_console
**CF Pages deploy**: https://cf60ab51.flapjack-cloud.pages.dev

## Probe Results

| # | Probe | Expected | Actual | Verdict |
|---|-------|----------|--------|---------|
| 00 | CI preflight | success | latest prod mirror CI run still red (playwright); manual deploy mode used | KNOWN |
| 00 | Pre-deploy status | — | prod API deploy status unchanged; behind_main 162 | NOTED |
| 00 | Merge + sync | branch merged to main and mirrors synced | completed via main worktree due local main worktree lock | PASS |
| 00 | CF Pages deploy | successful prod deploy | deployed https://cf60ab51.flapjack-cloud.pages.dev and cloud.flapjack.foo returns 200 | PASS |
| 00 | Live state ref | no blocking probe errors | only stripe_account_config ACTION_REQUIRED (operator-owned) | NOTED |
| 01 | /console auth guard | 303 -> /login | 303 -> /login | PASS |
| 02 | /dashboard root redirect | 308 -> /console | 308 -> /console | PASS |
| 03 | /dashboard/billing deep path | 308 -> /console/billing | 308 -> /console/billing | PASS |
| 04 | query-string preservation | 308 -> /console/billing?tab=invoices&page=2 | 308 -> /console/billing?tab=invoices&page=2 | PASS |
| 05 | OAuth google start | 302 -> accounts.google.com | 302 -> accounts.google.com | PASS |
| 06 | Web API_BASE_URL contract | prod -> api.flapjack.foo | PASS | PASS |
| 07 | /signup copy | 0 dashboard occurrences | no dashboard matches in SSR probe output | PASS |
| 08 | OAuth redirect URI contract | provider accepts prod callback URIs | google+github probes passed | PASS |
| 09 | Stripe portal return URL | no legacy /dashboard/billing references | default_return_url=null (session-level return_url ownership) | NOTED |
| 10 | local-ci | all 9 gates pass | all 9 gates pass | PASS |

## Overall Verdict

**PASS** — Production web deployment and live route probes confirm /dashboard permanently redirects to /console with query-string preservation, /console auth guard behavior is correct, OAuth contracts are healthy, and local CI passes. Non-blocking notes: prod mirror CI remains red on a pre-existing Playwright lane and Stripe portal configuration currently reports default_return_url: null under session-owned return-url behavior.
