---
created: 2026-06-04
updated: 2026-06-04
---

# browser_auth_setup Runtime Classification Fix

## Purpose

Document the Stage 4 follow-up investigation for the paid-beta RC
`browser_auth_setup` hard fail preserved in this bundle. This note is a written
deliverable for the repo-owned prerequisite fix; the original Stage 4 RC verdict
bundle remains unchanged and still records the run that actually executed.

## Evidence

- Preserved failing evidence: `browser_auth_setup.log` in this bundle shows
  `Error [ERR_MODULE_NOT_FOUND]: Cannot find package '@playwright/test' imported
  from .../web/playwright.config.ts`. That proves the RC harness reached
  Playwright config import with no local web Playwright runtime installed.
- Dependency contract: `web/package.json` declares `@playwright/test` under
  `devDependencies`, so the missing package is a local dependency installation
  prerequisite, not a product-code browser regression.
- Existing owner precedent: `scripts/lib/web_runtime.sh` owns
  `has_web_playwright_test_runtime` and the remediation text
  `web/node_modules/@playwright/test/package.json is missing; install web
  dependencies first with: cd web && npm ci`.
- Existing staging-lane precedent:
  `scripts/launch/run_browser_lane_against_staging.sh` already fails closed on
  the same local runtime prerequisite before invoking `npx`, preventing transient
  package resolution.
- RC harness owner before fix:
  `scripts/launch/run_full_backend_validation.sh` built `browser_auth_setup`
  directly with `npx playwright test ...`, so a checkout with no
  `web/node_modules/@playwright/test/package.json` could invoke transient
  Playwright and then fail as a hard `browser_auth_setup_failed` defect.

## Finding

The Stage 4 `browser_auth_setup` hard fail was a repo-owned harness
classification bug. The RC harness needed to reuse the existing web runtime
guard before invoking Playwright. Missing local web dependencies should be a
deterministic harness environment gap (`external_secret_missing` with reason
`browser_auth_setup_env_gap`), while real Playwright test failures should remain
hard `fail`.

During validation, the same shell owner exposed an adjacent parser defect:
`--staging-only` was documented and tested but parsed as an unknown argument.
That prevented the existing mode-pairing validation and staging-only RC path
from running. The parser now accepts `--staging-only`, and validation still
rejects it unless `--paid-beta-rc` is also present.

## Fix Summary

- `scripts/launch/run_full_backend_validation.sh` now sources
  `scripts/lib/web_runtime.sh`, checks `has_web_playwright_test_runtime` before
  `browser_auth_setup`, writes the shared install hint to
  `browser_auth_setup.log`, appends `external_secret_missing` /
  `browser_auth_setup_env_gap`, and avoids invoking `npx` when the runtime is
  missing.
- `scripts/lib/full_backend_validation_cli.sh` now parses `--staging-only` and
  preserves the existing validation contract that it requires `--paid-beta-rc`.
- `scripts/tests/full_backend_validation_test.sh` now asserts the missing-runtime
  classification, no-`npx` behavior, the preserved pass-path Playwright command,
  and the staging-only parser behavior.

## Validation

Command:

```bash
bash scripts/tests/full_backend_validation_test.sh
```

Result: `175 passed, 0 failed`.

The validation was recorded through `matt.validation_cache.record` for session
`s23-build-fixed-browser-auth-runtime`.

## Open Questions

- The original Stage 4 bundle remains `NOT-READY` because it represents the
  already-executed RC run. A future Wave-3 or rerun lane should decide whether
  to rerun the paid-beta RC harness after installing web dependencies.
- This fix classifies missing local Playwright runtime correctly; it does not
  prove that the browser auth setup itself passes once dependencies and browser
  binaries are present.
