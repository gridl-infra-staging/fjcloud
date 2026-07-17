# Cold Customer Algolia-Refugee Audit Stage 3 Browser Evidence

Created: 2026-06-04

## Purpose

Stage 3 reran the shipped remote Playwright browser owner against staging and reduced the result to a canonical browser evidence bundle for Stage 4 and Stage 5. This memo is evidence only; it does not fix the reproduced defect.

## Sources

- Stage 1 root and staging identity: `docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/preflight.md`.
- Remote-target gate and fixture env owner: `web/playwright.config.contract.ts`, especially `REMOTE_TARGET_OPT_IN_ENV`, `requireLoopbackHttpUrl()`, and `resolveFixtureEnv()`.
- Playwright project owner: `web/playwright.config.ts` maps `PLAYWRIGHT_PROJECT_CONTRACTS` into Playwright projects, including the `chromium` project dependency on `setup:user`.
- Journey owner: `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts:347` starts the cold-customer browser test body.
- Failure helper owner: `web/tests/fixtures/search-preview-helpers.ts:300` owns `waitForSearchPreviewHitsToContain()`.

## Bootstrap

Canonical evidence root:

```text
docs/runbooks/evidence/cold-customer-audit/20260604T172314Z
```

Browser evidence root:

```text
docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/browser
```

Resolved staging hosts:

```text
BASE_URL=https://cloud.staging.flapjack.foo
API_URL=https://api.staging.flapjack.foo
FLAPJACK_URL=https://api.staging.flapjack.foo
PLAYWRIGHT_TARGET_REMOTE=1
```

Bootstrap notes:

- The canonical secret file was readable at `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`.
- `scripts/launch/hydrate_seeder_env_from_ssm.sh staging` produced the shipped `*.flapjack.foo` hosts above.
- In this non-interactive Bash invocation, `source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)` only materialized `API_URL`; sourcing a temporary file containing the exact same hydrator output materialized all required exports. Stage 3 used the temp-file source form to preserve the canonical hydrator owner while avoiding that shell issue.
- The canonical secret file did not define `E2E_USER_EMAIL` or `E2E_USER_PASSWORD`. Stage 3 used the existing staging browser owner pattern from `scripts/launch/run_browser_lane_against_staging.sh` by generating a unique throwaway `E2E_USER_EMAIL/PASSWORD`; the cold-customer spec creates its own fresh customer through admin fixtures.
- `cd web && npm ci` was required because `web/node_modules` was absent; after install, `npx playwright --version` reported `Version 1.58.2`.

## Command Corrections

The checklist command used `--video=on`, but repo-local Playwright 1.58.2 rejected that with:

```text
error: unknown option '--video=on'
```

Local source evidence: `web/node_modules/playwright/lib/program.js` maps only `--trace` into normal test CLI `use` overrides in `overridesFromOptions()`. The normal `playwright test --help` output has `--trace <mode>` and no `--video` flag. Video requires a project/config `use.video` setting, and Stage 3 was not allowed to edit `web/playwright.config.ts`, `web/playwright.config.contract.ts`, or the spec.

Preflight command that passed:

```bash
cd web && BASE_URL="$STAGING_CLOUD_URL" \
  npx playwright test tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts \
    --project=chromium \
    --trace on \
    --output "$ABS_BROWSER_DIR/test-results" \
    --list
```

Preflight result:

```text
Listing tests:
  [setup:user] ... authenticate as customer
  [chromium] ... cold_customer_algolia_refugee_journey.spec.ts:347 ... public pricing to first uploaded-record search stays coherent on staging
Total: 2 tests in 2 files
```

Run command:

```bash
cd web && BASE_URL="$STAGING_CLOUD_URL" \
  npx playwright test tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts \
    --project=chromium \
    --trace on \
    --global-timeout 360000 \
    --output "$ABS_BROWSER_DIR/test-results" \
    2>&1 | tee "$ABS_BROWSER_DIR/run_stdout.log"
```

Playwright exit code:

```text
1
```

Exit code file:

```text
docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/browser/playwright_exit_code.txt
```

## Verdict Boundary

First failing owner boundary:

```text
web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts:396
assertFirstSearchFindsUploadedRecord()
  -> web/tests/fixtures/search-preview-helpers.ts:305
     waitForSearchPreviewHitsToContain(page, "Blue Ridge trail running vest", 45_000)
```

Failure text from `run_stdout.log`:

```text
Error: Waiting for Search Preview hits to contain "Blue Ridge trail running vest"
Expected substring: "Blue Ridge trail running vest"
Received string: ""
Timeout 45000ms exceeded while waiting on the predicate
```

Checkpoint interpretation:

- `setup:user` passed; the run did not fail before the spec body.
- The `chromium` journey reached the cold-customer spec body at `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts:347`.
- `/pricing` passed through the initial `assertPricingSurface()` call because execution advanced past `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts:366`.
- Signup validation, email verification replay, login, index creation, and five-record upload advanced past their owner calls because execution reached `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts:396`.
- The run reached `assertFirstSearchFindsUploadedRecord()` for `Blue Ridge trail running vest` and failed inside that owner while waiting for Search Preview card text.
- `assertAdjacentCustomerSurfaces()` did not run, so Stage 3 did not reach `/console/migrate` or `/console/billing`.

## Artifact Inventory

Canonical stdout log:

```text
docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/browser/run_stdout.log
```

Canonical Playwright output:

```text
docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/browser/test-results
```

Trace artifacts captured under `test-results`:

```text
docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/browser/test-results/fixtures-auth.setup.ts-authenticate-as-customer-setup-user/trace.zip
docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/browser/test-results/e2e-ui-full-cold_customer_-ff2ff-h-stays-coherent-on-staging-chromium/trace.zip
```

Failure screenshot:

```text
docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/browser/test-results/e2e-ui-full-cold_customer_-ff2ff-h-stays-coherent-on-staging-chromium/test-failed-1.png
```

Failure context:

```text
docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/browser/test-results/e2e-ui-full-cold_customer_-ff2ff-h-stays-coherent-on-staging-chromium/error-context.md
```

Copied HTML report:

```text
docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/browser/playwright-report/index.html
```

Artifact counts from automated validation:

```text
trace_count=2
video_count=0
```

The zero video count is a checklist command-surface issue, not a browser rerun absence: the shipped Playwright CLI/config path available to this research stage cannot force video without a config/spec change.

## Open Questions

- Stage 4 should determine why Search Preview produced no visible card text after the uploaded records were accepted by the Documents tab.
- Stage 4 should decide whether browser evidence must include video in future reruns and, if so, add a test-first repo-owned `use.video` setting or spec-local video owner in a build stage.
