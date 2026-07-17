# Playwright Fixture Salvage Worker Experiment Summary

## Verdict

keep workers: 1 - do not time or promote `--workers=2` or `--workers=4` yet. The serial Stage 2 control is red at HEAD, so higher-worker timing would measure against a broken baseline.

## Evidence Root

docs/runbooks/evidence/playwright-fixture-salvage/20260709T200658Z

## Repo State

- HEAD: `9505321701be23f020f70d44b43ec34786ee9905`
- Node: `v26.0.0`
- Playwright: `Version 1.58.2`
- Config default: `web/playwright.config.ts:151` has `workers: 1`
- Owner snapshot: `00_owner_snapshot.md`
- Comparability facts: `00_comparability.txt`

## Commands

```bash
perl -e 'alarm shift; exec @ARGV' 3600 bash -lc 'cd web && set -o pipefail && /usr/bin/time -p npm run test:e2e 2>&1 | tee "../docs/runbooks/evidence/playwright-fixture-salvage/20260709T200658Z/01_workers1_control.log"'
```

## workers: 1 Control

- Stack mode: Playwright-managed `webServer` path was used; the log contains `[WebServer]` output from `web/playwright.config.ts` and `Running 320 tests using 1 worker`.
- Result: FAIL
- Counts: 18 failed, 19 skipped, 283 passed
- Wall clock: real 998.31s; user 204.33s; sys 46.46s
- Log: `01_workers1_control.log`

## First-Failure Owner Diagnosis

The first red condition is the serial baseline itself, not worker contention. First observed failure:

- `web/tests/e2e-ui/mocked/overview_analytics_error.spec.ts:43` expected `getByTestId('search-widget')` to be visible, but the element was not found.

Additional serial failure families in the same control log:

- Recommendation specs: `getByLabel` strict-mode collisions because tooltip buttons and form controls share label text (`Object ID`, `Threshold`, `Facet Name`).
- Pricing journey: H1 rendered `Start free, scale into Paid storage`, while the spec expected lowercase `paid` or `Pricing`.
- Documents tab: missing `Browse Documents` button / `Browse Query` input.
- Merchandising hub dialog: missing label targets for `Enabled` and `Conditions JSON`.
- Overview enrichment: missing `Configure settings` navigation link.
- Console smoke: plan badge rendered `Paid Plan`, while the spec accepted only `Free Plan` or `Shared Plan`.
- Admin VLM screenshot tail: two `page.screenshot` calls failed with Chromium `Page.captureScreenshot` protocol errors. Online search found similar Playwright/Chromium reports (microsoft/playwright#38103 and microsoft/playwright#32144); this is recorded as a rerun-tail observation, not the primary stage blocker.

## Higher-Worker Conditions

`--workers=2` and `--workers=4` were not run. The checklist explicitly requires stopping the experiment when the `workers: 1` control is red.

## Next Migration Seam

Return to the Stage 2 serial-lane owners and restore `cd web && npm run test:e2e` to green at the default `workers: 1`; then re-run this experiment from a clean serial baseline.
