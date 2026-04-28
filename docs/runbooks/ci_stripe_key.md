# CI Stripe Key Setup

**Status:** Phase 0 step 5 (operator handoff).
**Audience:** repo operator with Stripe dashboard + GitHub org-secrets-write access.
**Goal:** unblock T1.4–T1.6 (Stripe webhook integration tests) without polluting the staging Stripe dashboard.

## Why a dedicated CI key

The staging app's runtime `STRIPE_SECRET_KEY` (sourced from SSM via [generate_ssm_env.sh](../../ops/scripts/lib/generate_ssm_env.sh)) is the staging-development test key — used by humans for manual exploration, by `staging_billing_dry_run.sh`, and by the running staging API. If CI tests reuse this same key:

1. Each CI run creates dozens of test customers + subscriptions + invoices.
2. After a few weeks of runs, `stripe customers list` returns thousands of `cus_*` records, drowning real test data.
3. `stripe events list` shows mostly CI noise, making incident debugging painful.
4. Any test that relies on "find recent customer" by email pattern can collide with another CI run's data.

**Fix:** create a **separate restricted-scope test-mode key** (`rk_test_*`), naming it `ci-only` in the Stripe dashboard. Keep the canonical env-var name `STRIPE_SECRET_KEY` per the existing pattern in [docs/design/secret_sources.md](../design/secret_sources.md) — only the *value* differs between the staging app's runtime SSM source and the GitHub Actions CI environment.

This avoids inventing a new env var (CLAUDE.md "single source of truth" rule) while still providing the dashboard isolation we need.

## Operator setup (one-time per environment)

### 1. Create the restricted key in Stripe

In the Stripe dashboard (test mode active):

1. Developers → API keys → "Create restricted key".
2. Name: `ci-only`.
3. Scope: **Test mode only.**
4. Permissions (set each to "Write" unless noted):
   - Customers
   - Subscriptions
   - Invoices
   - Payment Methods (Read + Write — needed for `setup_intent` flows)
   - Test Clocks
   - Webhooks (Read only — tests verify webhook handler reception, not webhook config)
   - Events (Read only)
5. All other resources: None.
6. Copy the `rk_test_*` value. **You cannot retrieve it later** — Stripe shows it once.

### 2. Add to GitHub Actions secrets (staging repo only)

Per CLAUDE.md "Deployment & CI/CD Flow": dev repos do not run CI. CI workflows live on the **staging repo** synced via debbie.

In the staging repo on GitHub:
- Settings → Secrets and variables → Actions → "New repository secret"
- Name: `STRIPE_SECRET_KEY`
- Value: the `rk_test_*` key from step 1.

Also add (for tests that use webhook signature verification):
- Name: `STRIPE_WEBHOOK_SECRET`
- Value: the test-mode webhook secret from Stripe dashboard → Developers → Webhooks → (test endpoint) → Signing secret.

### 3. CI customer naming convention

Tests must prefix all CI-created Stripe customer emails with `ci-{git_sha_short}-` so cleanup is mechanical:

```rust
// Inside test setup:
let email = format!("ci-{}-{}@test.flapjack.foo", env!("GITHUB_SHA")[..7], Uuid::new_v4());
```

This makes `stripe customers list --limit 100` filterable by prefix and lets the cleanup script (step 4) target only CI artifacts.

### 4. Cleanup cron (deferred until first dashboard pollution)

A `scripts/cleanup_ci_stripe_test_data.sh` is **not yet written** — defer until the dashboard actually shows pollution. Sketch when needed:
- List customers with email matching `ci-*@test.flapjack.foo`.
- For each, delete subscriptions and detach payment methods, then `stripe customers delete`.
- Schedule weekly via GHA cron OR run ad-hoc when the dashboard gets noisy.

The restricted key has the necessary scopes for this cleanup (Customers + Subscriptions + Payment Methods write).

## Test code contract (Stream C/D will follow this)

Tests must:

1. **Read the key via `optional_env("STRIPE_SECRET_KEY")`** (the helper in [`infra/api/src/provisioner/env_config.rs`](../../infra/api/src/provisioner/env_config.rs)). NOT raw `std::env::var()`.
2. **Skip with a clear message if absent** (so local `cargo test` doesn't fail when no key is configured):
   ```rust
   let Some(stripe_key) = optional_env("STRIPE_SECRET_KEY") else {
       eprintln!("SKIP: STRIPE_SECRET_KEY not set — set the CI restricted key per docs/runbooks/ci_stripe_key.md");
       return;
   };
   ```
3. **Refuse to run against a non-test key** — assert the key starts with `sk_test_` or `rk_test_`. Live keys must never reach a test:
   ```rust
   assert!(
       stripe_key.starts_with("sk_test_") || stripe_key.starts_with("rk_test_"),
       "STRIPE_SECRET_KEY must be a test-mode key in tests"
   );
   ```
4. **Use the `ci-{sha}-` email prefix** for any customer created.

## Rotation procedure

When the restricted key needs new permissions or after a suspected leak:
1. In Stripe dashboard, regenerate the `ci-only` restricted key (or create a new one and revoke the old).
2. Update the `STRIPE_SECRET_KEY` GHA secret in the staging repo with the new value.
3. No code change required — tests pick up the new value on next run.
4. If permissions were widened, audit which tests now have access they didn't have before.

## Why this lives in CI secrets, not in `.secret/.env.secret`

The staging app's runtime `STRIPE_SECRET_KEY` source is SSM Parameter Store (per [docs/design/secret_sources.md](../design/secret_sources.md)). CI is a different runtime; secrets that ONLY CI needs belong in CI's secret store (GHA secrets), not in the local `.env.secret` file or in SSM. Mixing them violates separation of concerns:
- A developer running `cargo test` locally should NOT accidentally hit the CI restricted key.
- The deployed staging app has no use for the CI key.

## Operator action checklist

- [ ] Step 1: create the `ci-only` restricted key in Stripe test mode and copy the `rk_test_*` value.
- [ ] Step 2: add `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` to the staging repo's GHA secrets.
- [ ] Verify by viewing the secret in GHA settings (value will be hidden but presence is shown).
- [ ] When Stream C/D lands the first webhook test, run it once in CI to confirm the key works end-to-end.
- [ ] When the staging Stripe dashboard first shows >100 `ci-*` customers, write `scripts/cleanup_ci_stripe_test_data.sh` and add a weekly cron.

## References

- [docs/design/secret_sources.md](../design/secret_sources.md) — canonical Stripe env var naming pattern
- [docs/design/stripe_environments.md](../design/stripe_environments.md) — sandbox vs test-mode vs live-mode model
- [chats/apr26_2pm_1_beta_launch_test_plan.md](../../chats/apr26_2pm_1_beta_launch_test_plan.md) — T1.4 (the test that needs this)
- [chats/apr26_6pm_1_phase_0_guide.md](../../chats/apr26_6pm_1_phase_0_guide.md) — Phase 0 step 5
