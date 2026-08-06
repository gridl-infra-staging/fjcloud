# CI Stripe Key Setup

**Status:** **DONE and verified 2026-08-05.** The operator handoff below was completed; this file is now
reference rather than a to-do. `STRIPE_SECRET_KEY` has existed in the `gridl-infra-staging/fjcloud`
Actions secrets since 2026-07-17, and it demonstrably works: the `stripe-test-clock-live` job in
`.github/workflows/nightly.yml` runs `cargo test -p api --test billing stripe_test_clock_full_cycle_test::`
under `BACKEND_LIVE_GATE=1` — where `require_live!` **panics** rather than skips on an unusable key — and
that job passes. Re-derive with `gh secret list --repo gridl-infra-staging/fjcloud` and
`gh run list --workflow=nightly.yml`.

> **Three secrets are referenced by `nightly.yml` but absent from the repo, so they expand to empty
> strings: `STRIPE_WEBHOOK_SECRET`, `INTEGRATION_API_BASE`, `INTEGRATION_DB_URL`.** The jobs that
> reference them currently pass, which means no passing assertion depends on them today — but that is a
> property of the current test selection, not a guarantee. Adding a test that needs any of the three will
> fail on an empty value rather than a missing-secret message. Step 2 below still describes adding
> `STRIPE_WEBHOOK_SECRET`; it has not been done.
>
> Nightly is currently **red for an unrelated reason**: the `pricing-freshness` job fails on
> `pricing_freshness_wall_clock_tripwire`, an `#[ignore]`d and explicitly non-deploy-gating wall-clock
> tripwire in `infra/pricing-calculator/src/lib.rs` that fires when competitor pricing metadata is more
> than 90 days unverified. That is the tripwire doing its job, not a Stripe-key fault.

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

### 4. Cleanup cron (pollution has now occurred; cleanup still deliberately deferred)

**Measured 2026-08-05 with `STRIPE_SECRET_KEY_RESTRICTED` against the default sandbox:** paginating
`/v1/customers` returned **6,000 customers without reaching the end**, accruing at a steady **~285/day**
(2026-07-27 through 2026-08-05 each within 281–342), reaching back to at least 2026-06-27. Every sampled
address matched a fixture shape. So the "after a few weeks of runs … thousands of `cus_*` records"
scenario in *Why a dedicated CI key* above is no longer hypothetical — it has happened.

**Root cause, which is not what this section assumed.** The leak is not a missing cron; it is that
nothing ever deletes the Stripe side. `web/tests/fixtures/fixtures.ts::deleteTrackedCustomerForCleanup`
issues `DELETE /admin/tenants/{customerId}`, which removes the **fjcloud tenant** and never the **Stripe
customer**, so every fixture run that reaches Stripe leaves one behind permanently. A cron would mop up
after a leak that the fixture layer could simply stop creating.

**Correction to the sketch below — it would delete nothing as written.** It filters on
`ci-*@test.flapjack.foo`, but the addresses actually produced are of the form
`billing-portal-<seed>@e2e.griddle.test` and `<prefix>-<seed>@e2e.griddle.test`. Any cleanup built on the
documented pattern would report success having matched zero rows — a silent no-op of exactly the kind the
no-manual-QA rule forbids. Fix the pattern against real data before trusting any such script.

**Decision (2026-08-05): still deferred, now with a stated reason rather than an unfired trigger.** The
pollution is **noise, not a correctness risk**: nothing looks Stripe customers up by pattern. `grep` over
`web/tests/`, `scripts/`, and `infra/api/src/` finds no `/v1/customers` list-or-search call and no
email-pattern lookup — the `find_by_email` implementations are the Postgres customer repo, not Stripe. So
the "CI run collides with another run's data" hazard listed above does not currently apply, and a
destructive bulk-delete over 6,000+ objects is more risk than the noise justifies.

**Promote this to real work when either becomes true:** (a) any test or product path starts resolving
Stripe customers by list, search, or email pattern — at which point accumulated fixture rows become a
correctness hazard, not clutter; or (b) an operator is actually impeded in the dashboard. The durable fix
is (a)-proof anyway: have the fixture that creates a Stripe customer delete it, so cleanup lives with
creation instead of in a cron.

Sketch retained for when it is needed (pattern corrected per above):
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
