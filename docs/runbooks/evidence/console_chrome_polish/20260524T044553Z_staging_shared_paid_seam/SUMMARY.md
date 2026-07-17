# Console Chrome Polish Stage 2 Evidence

- Spec path: `web/tests/e2e-ui/full/console_chrome_polish.spec.ts`
- Target command: `cd web && npx playwright test tests/e2e-ui/full/console_chrome_polish.spec.ts --project=chromium --reporter=list --no-deps`
- Result: **RED only (blocked before green)**

## Pass/Fail by seam requirement
- `/account` payload contains `billing_plan: shared`: FAIL (cannot force shared state; admin key rejected by staging).
- `/console` renders `Paid Plan`: NOT REACHED.
- `BetaPill` visible with `/beta` link: NOT REACHED.
- Legacy hook `dashboard-beta-support-badge` absent in active shell: PASS (no matches in `web/src/routes/console` or `web/src/lib/components`; spec-only assertion reference remains).
- Footer links (`/terms`, `/privacy`, `/dpa`, `/status`) visible in console: NOT REACHED.

## Blocker Evidence
- Remote-target guard rejected non-allowlisted host (`staging.flapjack.cloud`) under `PLAYWRIGHT_TARGET_REMOTE=1`.
- Allowlisted host run (`cloud.flapjack.foo`/`api.flapjack.foo`) reached spec but failed due credential mismatch:
  - `Auth login failed: 400 {"error":"invalid email or password"}`
  - `401 {"error":"invalid admin key"}` on shared-plan mutation/fixture cleanup.
