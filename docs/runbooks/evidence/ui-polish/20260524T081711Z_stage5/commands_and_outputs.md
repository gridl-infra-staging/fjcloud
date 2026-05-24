# Stage 5 Evidence

## Local Rust owner test (RED then GREEN)

### Command
```bash
cd infra && cargo test -p api --test public_site_test
```

### Output (RED)
```text
test root_serves_public_landing_page_with_review_metadata ... FAILED
assertion failed: body.contains("--font-brand")
```

### Output (GREEN)
```text
running 11 tests
...
test root_serves_public_landing_page_with_review_metadata ... ok
...
test result: ok. 11 passed; 0 failed
```

### Post-green correction
```text
Fixed lingering `.band { background: var(--cream); }` reference to `.band { background: var(--color-flapjack-cream); }` in public_site.rs and re-ran `cargo test -p api --test public_site_test` (11 passed).
```

## Local web owners

### Command
```bash
cd web && npm run lint && npm run build
```

### Output
```text
> web@0.0.1 lint
> prettier --check . && eslint .
All matched files use Prettier code style!

> web@0.0.1 build
> vite build
✓ built in 2.24s (client)
✓ built in 4.27s (server)
```

### Command
```bash
cd web && npx vitest run src/routes/landing.test.ts src/routes/layout.test.ts src/routes/console/layout.test.ts --reporter=default
```

### Output
```text
Test Files  3 passed (3)
Tests  81 passed (81)
```

### Command
```bash
# Playwright's `webServer` config (web/playwright.config.ts → playwright.config.contract.ts:346)
# auto-starts ../scripts/playwright_local_stack.sh on http://localhost:5173 when
# BASE_URL is unset, and tears it down on exit. No separate `npm run preview`
# step is needed — invoking `playwright test` directly is the reproducible form.
cd web && npx playwright test tests/e2e-ui/full/public-pages.spec.ts --project=chromium:public
```

### Output
```text
12 passed (22.3s)
```

### Command
```bash
cd web && npx playwright test tests/e2e-ui/full/console.spec.ts tests/e2e-ui/full/index-detail.spec.ts --project=chromium
```

### Output
```text
26 passed, 4 skipped (31.9s)
```

## Repo gate

### Command
```bash
bash scripts/local-ci.sh
```

### Output
```text
Result: FAIL
Failing gates: rust-lint, web-lint, web-test
rust-lint: formatting deltas in infra/api/src/auth/api_key.rs and infra/api/tests/api_key_auth_test.rs
web-test: failures in web/src/routes/console/error.test.ts and web/src/routes/terms/terms.test.ts
```

## Staging verification (remote target)

### Command
```bash
PLAYWRIGHT_TARGET_REMOTE=1 BASE_URL=https://cloud.staging.flapjack.foo API_URL=https://api.staging.flapjack.foo bash scripts/e2e-preflight.sh
```

### Output
```text
PREFLIGHT PASSED: all checks OK.
```

### Command
```bash
cd web && PLAYWRIGHT_TARGET_REMOTE=1 BASE_URL=https://cloud.staging.flapjack.foo API_URL=https://api.staging.flapjack.foo npx playwright test tests/fixtures/auth.setup.ts --project=setup:user --reporter=list
```

### Output
```text
1 passed (1.6s)
```

### Command
```bash
cd web && PLAYWRIGHT_TARGET_REMOTE=1 BASE_URL=https://cloud.staging.flapjack.foo API_URL=https://api.staging.flapjack.foo npx playwright test tests/e2e-ui/full/public-pages.spec.ts --project=chromium:public --reporter=list
```

### Output
```text
Result: FAIL
5 failed, 7 passed
Key failures: missing landing elements/CTAs expected by public-pages spec on staging deployment
```

### Command
```bash
cd web && PLAYWRIGHT_TARGET_REMOTE=1 BASE_URL=https://cloud.staging.flapjack.foo API_URL=https://api.staging.flapjack.foo npx playwright test tests/e2e-ui/full/console.spec.ts tests/e2e-ui/full/index-detail.spec.ts --project=chromium --reporter=list
```

### Output
```text
Result: FAIL
16 failed, 11 passed, 3 skipped
Key failures include missing brand-logo in console shell and repeated fixture seeding/admin-plan 401 invalid admin key responses.
```
