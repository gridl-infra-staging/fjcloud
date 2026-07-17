# Polished Beta Staging Verification

## Probe

- UTC bundle: `20260610T095108Z`
- Target web: `https://cloud.staging.flapjack.foo`
- Target API: `https://api.staging.flapjack.foo`
- Dev main SHA: `06c25684ef7fd983d14f3fe3d49dca6937d30ff0`
- Staging `dev_sha`: `ce5b08c16e5f900c592b5c62f39987e1351891ce`
- Prod `dev_sha` before/after: `06c25684ef7fd983d14f3fe3d49dca6937d30ff0`
- Staging deploy lag: `38` commits behind `origin/main`
- SHA drift during run: none for staging

## Command

```bash
PLAYWRIGHT_TARGET_REMOTE=1 BASE_URL=https://cloud.staging.flapjack.foo PLAYWRIGHT_BASE_URL=https://cloud.staging.flapjack.foo API_URL=https://api.staging.flapjack.foo API_BASE_URL=https://api.staging.flapjack.foo PLAYWRIGHT_HTML_REPORT="$BUNDLE/playwright-report" PLAYWRIGHT_JSON_OUTPUT_NAME="$BUNDLE/playwright-results.json" npx playwright test tests/e2e-ui/full/polished_beta_staging_verify.spec.ts --project=chromium --grep '@staging_verify' --reporter=html,json
```

## Result

| Lane | Status | Evidence |
| --- | --- | --- |
| Setup | PASS | `authenticate as customer` passed. |
| A | FAIL | Reached UI assertion; expected `Merchandising hub` heading was not visible in `merchandising-section`. |
| B | FAIL | Reached UI assertion; deployed page still exposed a `Rules` tab. |
| C | FAIL | Blocked before UI assertion: `seedSearchableIndex: key creation failed after retries: 404 {"error":""}`. |
| D | FAIL | Blocked before UI assertion: same searchable-index key creation 404. |
| E | FAIL | Blocked before UI assertion: same searchable-index key creation 404. |
| F | FAIL | Blocked before UI assertion: same searchable-index key creation 404. |
| G | PASS | Executable defer-guard confirmed `chats/icg/jun09_pm_merch_mode_pin_staging_followup.md` captures the missing merch-mode contract. |

## Follow-Ups

- `chats/icg/jun09_pm_merchandising_hub_staging_lag_followup.md`
- `chats/icg/jun09_pm_searchable_index_key_creation_staging_followup.md`
- `chats/icg/jun09_pm_merch_mode_pin_staging_followup.md`

## Artifacts

- JSON report: `docs/runbooks/evidence/polished-beta-staging-verify/20260610T095108Z/playwright-results.json`
- HTML report: `docs/runbooks/evidence/polished-beta-staging-verify/20260610T095108Z/playwright-report/`
- Deploy state before: `docs/runbooks/evidence/polished-beta-staging-verify/20260610T095108Z/deploy_status_before.json`
- Deploy state after: `docs/runbooks/evidence/polished-beta-staging-verify/20260610T095108Z/deploy_status_after.json`

## Local Static Validation

- `cd web && pnpm exec vitest run src/tests/e2e-fixture-user-helpers.test.ts` passed: 97 tests.
- `cd web && npx playwright test --list tests/e2e-ui/full/polished_beta_staging_verify.spec.ts --grep '@staging_verify' | grep -cE '^\\s+\\['` returned `8`.
- `cd web && pnpm exec prettier --check tests/e2e-ui/full/polished_beta_staging_verify.spec.ts tests/fixtures/fixtures.ts src/tests/e2e-fixture-user-helpers.test.ts` passed after formatting `tests/fixtures/fixtures.ts`.
- `cd web && pnpm exec eslint --config tests/e2e-ui/eslint.config.mjs tests/e2e-ui/full/polished_beta_staging_verify.spec.ts` passed.
