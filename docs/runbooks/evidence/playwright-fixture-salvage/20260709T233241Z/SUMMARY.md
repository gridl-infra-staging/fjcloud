# Playwright Fixture Salvage Worker Experiment Summary

## Verdict

keep workers: 1. Do not promote `workers: 2` or `workers: 4`.

The corrected Stage 3 bar compares failing sets against the known red workers:1 baseline. `workers: 2` was faster, but the second full run introduced a new failure versus the baseline, so it failed the three-consecutive subset-only promotion rule. `workers: 4` was faster but immediately introduced five new failures.

## Evidence Root

`docs/runbooks/evidence/playwright-fixture-salvage/20260709T233241Z`

## Repo State

- HEAD: `ba001e6efd322fb33d4927cf0967dc8ea88bcedf`
- Config default remains `web/playwright.config.ts:151` with `workers: 1`.
- Playwright-managed `webServer` stack path was used for all full-lane measurements.
- Owner snapshot: `00_owner_snapshot.md`.
- Comparability facts: `00_comparability.txt`.

## Commands And Results

### workers1

- Real times: 1033.57s
- Median real: 1033.57s
- Run 1: `docs/runbooks/evidence/playwright-fixture-salvage/20260709T230655Z/01_workers1_control.log`; counts: 18 failed, 19 skipped, 283 passed (17.2m)

### workers2

- Real times: 547.82s, 568.00s
- Median real: 557.91s
- Run 1: `docs/runbooks/evidence/playwright-fixture-salvage/20260709T233241Z/02_workers2_run1.log`; counts: 18 failed, 19 skipped, 283 passed (9.1m)
- Run 2: `docs/runbooks/evidence/playwright-fixture-salvage/20260709T233241Z/06_workers2_run2.log`; counts: 19 failed, 19 skipped, 282 passed (9.5m)

### workers4

- Real times: 420.48s
- Median real: 420.48s
- Run 1: `docs/runbooks/evidence/playwright-fixture-salvage/20260709T233241Z/03_workers4_run1.log`; counts: 23 failed, 19 skipped, 1 did not run, 277 passed (7.0m)

## Failing Set Diffs

### workers2 run 1

- New failures vs workers:1 baseline: 0
  - none

### workers2 run 2

- New failures vs workers:1 baseline: 1
  - [chromium] › tests/e2e-ui/full/console.spec.ts:190:2 › Dashboard page › mobile sidebar link to Billing reaches the billing page

### workers4 run 1

- New failures vs workers:1 baseline: 5
  - [chromium:admin] › tests/e2e-ui/full/admin/customer-detail.spec.ts:262:2 › Admin customer detail workflows › quota update form submits and shows success feedback
  - [chromium:mocked] › tests/e2e-ui/mocked/events_auto_poll.spec.ts:5:2 › Events tab — auto-poll cadence › fires a refreshEvents form POST roughly every 5s while polling is active
  - [chromium:mocked] › tests/e2e-ui/mocked/events_visibility_pause.spec.ts:9:2 › Events tab — visibility pause/resume › polling pauses while tab is hidden and resumes within debounce window on visible
  - [chromium:mocked] › tests/e2e-ui/mocked/security_sources_error_state.spec.ts:18:1 › Security Sources tab renders forced load error state and retry affordance
  - [setup:customer-journeys] › tests/fixtures/onboarding-auth-shared.ts:122:2 › create fresh account for customer journeys

## Contention Diagnosis

- `workers: 4` first new setup failure was `setup:customer-journeys`; the page snapshot showed the signup form alert `We could not create your account...`. The corrected isolated rerun of `tests/fixtures/customer-journeys.auth.setup.ts --project=setup:customer-journeys --workers=4` passed in 10.73s, so this requires suite-level concurrency.
- `workers: 4` event/security new failures landed on a 404 `Index not found` page for freshly seeded `e2e-*` indexes. The fixture owner is `web/tests/fixtures/fixtures.ts` passive stale cleanup (`cleanupStaleFixtureIndexesOnce`) plus the broad `STALE_FIXTURE_INDEX_PREFIXES` contract in `scripts/lib/stale_fixture_contract.sh`; worker-local cleanup can delete another worker's fresh `e2e-*` index.
- `workers: 2` run 2 introduced `web/tests/e2e-ui/full/console.spec.ts:190` where mobile sidebar navigation stayed on `/console` and never rendered the Billing heading. This is a navigation/state contention symptom outside the serial baseline.
- No config promotion was made; `web/playwright.config.ts` remains serial.

## Validation Notes

- Validation-cache misses were checked before the new full-lane commands.
- Recorded validation-cache observations for worker-2 run 1, worker-4 run 1, the corrected setup rerun, and worker-2 run 2.
- Final local CI result is recorded separately after this summary is written.
