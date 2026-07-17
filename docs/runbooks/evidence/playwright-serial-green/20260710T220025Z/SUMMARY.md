# Serial Playwright Baseline Green — Evidence Summary

## Gate Verdict: PASS

The full serial Playwright suite (`workers: 1`) is deterministically green at HEAD `58780acf24dc34fa2cbb5c1193ff33ccf70a53c9`.

## Two Passing Full Runs

| Run | Result | Duration |
|-----|--------|----------|
| run1.log | 19 skipped, 301 passed (10.3m) | 0 failed |
| run2.log | 19 skipped, 301 passed (10.1m) | 0 failed |

Both runs executed with `workers: 1`, `retries: 0`, `fullyParallel: false`.

## Lint

- `lint_e2e.log`: 0 errors, 168 warnings. Exit 0.
- `local-ci --fast`: 18 gates PASS, 0 fail, 0 skip (36s wall).

## Local Stack

Playwright's configured `webServer` (via `runtimeContract.webServer` in `web/playwright.config.ts`) was sufficient. No separate local stack (`scripts/playwright_local_stack.sh`, `scripts/local-dev-up.sh`) was started.

## Workers > 1

Parallel execution (`workers > 1`) remains intentionally deferred. This evidence bundle proves the serial baseline only.

## Per-Failure Dispositions

`triage.md` in this directory is the per-row source of truth for all 19 formerly failing tests and their final outcomes. All were resolved by three Stage 2 commits:

- `74854ddcf` Fix overview export blob cleanup timing (1 failure, bucket a)
- `bcab9746b` Repair stale Playwright spec expectations (16 failures, bucket b)
- `dd6a3b5ab` Stabilize admin VLM desktop capture (2 failures, bucket b)

Stage 3 needed no new browser fixes.

## Bundle Contents

- `run1.log` — first serial proof run
- `run2.log` — second serial proof run
- `lint_e2e.log` — E2E lint capture
- `triage.md` — per-failure triage with final outcomes
- `SUMMARY.md` — this file
