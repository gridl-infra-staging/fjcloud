# Polished Beta Staging Verify Evidence

## Probe

- Probe time: `2026-06-10T09:08:38Z`
- Bundle path: `docs/runbooks/evidence/polished-beta-staging-verify/20260610T090838Z`
- HTML report: `docs/runbooks/evidence/polished-beta-staging-verify/20260610T090838Z/playwright-report`
- JSON report: `docs/runbooks/evidence/polished-beta-staging-verify/20260610T090838Z/playwright-results.json`

## Deploy State

| Field | Before | After |
| --- | --- | --- |
| dev main SHA | `06c25684ef7fd983d14f3fe3d49dca6937d30ff0` | `06c25684ef7fd983d14f3fe3d49dca6937d30ff0` |
| staging dev SHA | `ce5b08c16e5f900c592b5c62f39987e1351891ce` | `ce5b08c16e5f900c592b5c62f39987e1351891ce` |
| staging commits behind main | `38` | `38` |
| prod dev SHA | `ce5b08c16e5f900c592b5c62f39987e1351891ce` | `ce5b08c16e5f900c592b5c62f39987e1351891ce` |
| prod commits behind main | `38` | `38` |

Staging `dev_sha` did not change during the run. Results are not SHA-drifted, but staging is 38 commits behind `origin/main`.

## Exact Live Command

```bash
PLAYWRIGHT_TARGET_REMOTE=1 BASE_URL=https://cloud.staging.flapjack.foo PLAYWRIGHT_BASE_URL=https://cloud.staging.flapjack.foo API_URL=https://api.staging.flapjack.foo API_BASE_URL=https://api.staging.flapjack.foo PLAYWRIGHT_HTML_REPORT="$BUNDLE/playwright-report" PLAYWRIGHT_JSON_OUTPUT_NAME="$BUNDLE/playwright-results.json" npx playwright test tests/e2e-ui/full/polished_beta_staging_verify.spec.ts --project=chromium --grep '@staging_verify' --reporter=html,json
```

## Result Classification

The live Playwright run did not reach customer-visible lane assertions. The authenticated setup created customers but email verification replay failed for every `@staging_verify` lane because the staging DB token lookup could not use SSM.

Direct SSM smoke evidence:

```text
AWS_ACCESS_KEY_ID=set
AWS_DEFAULT_REGION=us-east-1
aws: [ERROR]: An error occurred (AuthFailure) when calling the DescribeInstances operation: AWS was not able to validate the provided access credentials
```

The browser failures are therefore classified as environment credential failures, not deployed product failures.

| Lane | Status | Classification | Evidence |
| --- | --- | --- | --- |
| A - Merchandising hub renders rules and no legacy search canvas | Red before lane assertions | Environment credential failure | `fresh-signup email verification replay setup failed before reaching /verify-email/{token}` |
| B - Rules tab slug lands on merchandising hub | Red before lane assertions | Environment credential failure | `fresh-signup email verification replay setup failed before reaching /verify-email/{token}` |
| C - Unified Search renders image-backed document cards | Red before lane assertions | Environment credential failure | `fresh-signup email verification replay setup failed before reaching /verify-email/{token}` |
| D - Display Preferences exposes document card controls | Red before lane assertions | Environment credential failure | `fresh-signup email verification replay setup failed before reaching /verify-email/{token}` |
| E - Query metrics report hit count and processing time | Red before lane assertions | Environment credential failure | `fresh-signup email verification replay setup failed before reaching /verify-email/{token}` |
| F - Numbered pagination reaches first second and last pages | Red before lane assertions | Environment credential failure | `fresh-signup email verification replay setup failed before reaching /verify-email/{token}` |
| G - Merchandising rule creation replaces old pin controls | Red before lane assertions | Environment credential failure plus prerequisite gap | `fresh-signup email verification replay setup failed before reaching /verify-email/{token}` |

## Follow-Up Stubs

- `chats/icg/jun09_pm_merch_mode_pin_staging_followup.md` records the missing merch-mode pin contract prerequisite for Lane G.

## Local Validation

- `cd web && npx playwright test --list tests/e2e-ui/full/polished_beta_staging_verify.spec.ts --grep '@staging_verify' | grep -cE '^\s+\['` returned `8`.
- `cd web && pnpm exec prettier --write tests/e2e-ui/full/polished_beta_staging_verify.spec.ts && pnpm exec prettier --check tests/e2e-ui/full/polished_beta_staging_verify.spec.ts && pnpm exec eslint --config tests/e2e-ui/eslint.config.mjs tests/e2e-ui/full/polished_beta_staging_verify.spec.ts` passed.
- `cd web && pnpm run lint` failed on pre-existing unrelated formatting drift in `src/lib/rules/ruleHelpers.ts`, `src/lib/search_templates/search_templates.server.test.ts`, `src/routes/console/indexes/[name]/tabs/SynonymsTab.svelte`, `tests/e2e-ui/full/oauth_round_trip.spec.ts`, and `tests/fixtures/fixtures.ts`; the new Stage 1 spec was not listed.

## Bundle Validation

```bash
test -s "$BUNDLE/SUMMARY.md" && test -d "$BUNDLE/playwright-report" && test -s "$BUNDLE/playwright-results.json"
```
