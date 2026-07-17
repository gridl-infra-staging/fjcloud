# Stage 3 Browser Search Preview Evidence

## Commands

- Hydration used the stale-AWS-env-cleared fallback because inherited AWS credentials returned `InvalidClientTokenId`; the exact fallback command shape is recorded in `hydration_command.txt`.
- Browser rerun stdout is in `run_stdout.log`.
- Playwright artifacts are under `test_results/`. The checked-in trace archive is a redacted placeholder because raw Playwright traces capture live cookies and preview bearer headers.
- The current staging custom host was deployed with `npx wrangler pages deploy .svelte-kit/cloudflare --project-name=flapjack-cloud --branch=staging --commit-hash "$(git rev-parse HEAD)"`; stdout is in `wrangler_pages_staging_deploy.log`.

## Result

- `https://cloud.staging.flapjack.foo/_app/version.json` returned `18d48ba60cbdb1e087ae28142ce28ca0613c5a07` before the final browser rerun.
- The cold-customer browser journey passed against staging: `1 passed (48.7s)` in `run_stdout.log`.
- The passing run reached `assertFirstSearchFindsUploadedRecord()` and kept the real `waitForSearchPreviewHitsToContain(page, "Blue Ridge trail running vest", 45_000)` assertion.
- The same passing run continued through the adjacent migrate, billing, and pricing surfaces after Search Preview.
- F3/F4/F6/F7/F8 are settled for the browser Search Preview path by the live customer-visible result: the journey created the customer/index, uploaded the five fixture records, generated the preview key, queried through `/api/search/<index>`, and rendered `Blue Ridge trail running vest` from staging UI on `cloud.staging.flapjack.foo`.

## Fix Landed

- Commit `9f36170d69f9f5328c75a7d1275c26205498d57c` fixes the same-origin Search Preview proxy so it accepts the authenticated customer's tenant-scoped preview index UID and forwards that scoped UID to the Flapjack node.
- The helper now retries preview-key regeneration during hit polling when the UI surfaces another expired-key state, preserving the real expected-hit assertion without capping recovery at a single retry.
- The follow-up route fix reuses the shared Search Preview request-header contract from `$lib/flapjack-search-client` so the same-origin proxy and browser client cannot drift on `X-Algolia-Application-Id` or bearer forwarding again.
- No Stage 3 spec-file edit was required for the adjacent migrate, billing, and pricing assertions; the final passing rerun continued through those surfaces unchanged after the proxy and helper fixes landed.

## Validation

- `cd web && npm test -- search-preview-helpers.test.ts search.server.test.ts` passed: 25 tests.
- Red regression: `cd web && npm test -- search.server.test.ts` failed before the app-id fix because the route and browser client used different Search Preview app-id contracts.
- `cd web && npm test -- search.server.test.ts` passed after the app-id fix: 15 tests.
- `PLAYWRIGHT_TARGET_REMOTE=1 BASE_URL=https://cloud.staging.flapjack.foo API_URL=https://api.staging.flapjack.foo API_BASE_URL=https://api.staging.flapjack.foo E2E_ADMIN_KEY="$E2E_ADMIN_KEY" npx playwright test --config playwright.config.ts --project=chromium --reporter=list --trace on --output ../docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/browser/test_results --no-deps tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts` passed from `web/`.
- `cd web && npm run lint:e2e` exited 0 with existing warnings; stdout is in `lint_e2e_stdout.log`.
- `bash scripts/local-ci.sh --fast` passed 14 gates; stdout is in `local_ci_fast_stdout.log`.

## Remaining

- None for Stage 3 browser rerun and closeout validation.
