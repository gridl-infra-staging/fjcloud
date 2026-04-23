# Secret Rotation Runbook

## Purpose

This runbook defines operator rotation steps for Stripe, SES, and JWT signing secrets.
Keep variable definitions in [`docs/env-vars.md`](../env-vars.md) as the single source of truth.
For SES setup and readiness details, use [`docs/runbooks/email-production.md`](email-production.md).

## Scope And Runtime Constraints

- This runbook documents current behavior only; it does not add multi-key JWT support.
- The API currently uses a single `JWT_SECRET` with no overlap window for old and new tokens.
- Rotations here are deploy-time cutovers; no live in-process secret reload is implemented.

## Stripe Rotation

### Contract Anchors

- Canonical key resolution and checks:
  - `scripts/lib/stripe_checks.sh::resolve_stripe_secret_key`
  - `scripts/lib/stripe_checks.sh::check_stripe_key_present`
  - `scripts/lib/stripe_checks.sh::check_stripe_key_live`
  - `scripts/lib/stripe_checks.sh::check_stripe_webhook_secret_present`
- Validation command: `scripts/validate-stripe.sh`
- Launch gate context: [`docs/runbooks/launch-backend.md`](launch-backend.md)
- Variable contract: [`docs/env-vars.md#stripe`](../env-vars.md#stripe)

`STRIPE_SECRET_KEY` is the canonical operator variable. `STRIPE_TEST_SECRET_KEY` is a compatibility fallback only when `STRIPE_SECRET_KEY` is unset.

### Prechecks

1. Confirm the new Stripe key is available as `STRIPE_SECRET_KEY` and starts with `sk_test_` for non-live validation contexts.
2. Confirm `STRIPE_WEBHOOK_SECRET` is available and starts with `whsec_`.
3. Confirm the current shell/environment does not rely on `STRIPE_TEST_SECRET_KEY` unless explicitly using compatibility fallback behavior.

### Cutover

1. Update secret storage/session-manager entries so `STRIPE_SECRET_KEY` points to the new value.
2. Update `STRIPE_WEBHOOK_SECRET` if webhook signing secret rotation is part of the same window.
3. Deploy/restart API processes that consume Stripe env vars.
4. Keep `STRIPE_TEST_SECRET_KEY` unset unless a compatibility-only automation path still requires it temporarily.

### Rollback Expectations

1. Restore the previous known-good `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` values.
2. Deploy/restart API processes to reload the previous values.
3. Expect Stripe-authenticated checks to fail until rollback deploy completes.

### Post-rotation verification

1. Run:

```bash
STRIPE_SECRET_KEY=sk_test_... STRIPE_WEBHOOK_SECRET=whsec_... bash scripts/validate-stripe.sh
```

2. Confirm output JSON reports `"passed": true`.
3. If launch validation is in scope, run the relevant Stripe checks from [`docs/runbooks/launch-backend.md`](launch-backend.md).

## SES Rotation

### Contract Anchors

- Startup validation path: `infra/api/src/services/email.rs::SesConfig::from_reader`
- Readiness script: `scripts/validate_ses_readiness.sh`
- Canonical SES runbook: [`docs/runbooks/email-production.md`](email-production.md)
- Variable contract: [`docs/env-vars.md#email-ses`](../env-vars.md#email-ses)

This runbook keeps SES rotation narrow to `SES_FROM_ADDRESS` and `SES_REGION`. AWS credential chain behavior remains owned by [`docs/runbooks/email-production.md`](email-production.md) under its "AWS credential chain" section.

### Prechecks

1. Confirm target `SES_FROM_ADDRESS` identity is verified in the target account/region.
2. Confirm target `SES_REGION` matches where the identity is verified.
3. Confirm the AWS credential chain context required by the email-production runbook is healthy before cutover.

### Cutover

1. Update `SES_FROM_ADDRESS` and/or `SES_REGION` in the runtime secret source.
2. Deploy/restart API processes so startup re-runs `SesConfig::from_reader` against updated values.
3. If startup fails, treat that as a contract failure (missing/empty SES envs) and roll back immediately.

### Rollback Expectations

1. Restore the previous `SES_FROM_ADDRESS`/`SES_REGION` pair.
2. Deploy/restart API processes to restore known-good startup configuration.
3. Do not define alternate SES secret contracts in this runbook; continue to use env-vars + email-production docs.

### Post-rotation verification

1. Run:

```bash
SES_FROM_ADDRESS=noreply@example.com SES_REGION=us-east-1 \
  bash scripts/validate_ses_readiness.sh --identity noreply@example.com --region us-east-1
```

2. Confirm readiness output reports identity verified and no blocking errors.
3. For deeper SES readiness and non-goals, continue with [`docs/runbooks/email-production.md`](email-production.md).

## JWT Rotation

### Contract Anchors

- Startup config load: `infra/api/src/config.rs::Config::from_reader`
- Startup wiring (single loaded secret at process start): `infra/api/src/main.rs`, `infra/api/src/state.rs`
- Sign path: `infra/api/src/routes/auth.rs::issue_jwt`
- Verify paths:
  - `infra/api/src/auth/tenant.rs::AuthenticatedTenant::from_request_parts`
  - `infra/api/src/router/middleware.rs::extract_tenant_id_from_jwt`
  - `infra/api/src/middleware/request_logging.rs::RequestSpan::extract_tenant_id`

The current design uses a single JWT_SECRET value loaded at startup. The same secret signs and verifies tokens. Rotation is not seamless because there is no multi-key overlap support.

### Prechecks

1. Announce maintenance impact: rotation will invalidate outstanding bearer tokens after cutover.
2. Ensure client-facing teams are ready for forced re-authentication.
3. Prepare a rollback value for `JWT_SECRET` before changing production config.

### Cutover

1. Update `JWT_SECRET` in runtime secret storage.
2. Deploy/restart API processes so the new secret is loaded by `Config::from_reader` into `AppState`.
3. Expect existing bearer tokens minted before deploy/restart to fail verification immediately after cutover.

### Rollback Expectations

1. Restore prior `JWT_SECRET` value.
2. Deploy/restart API processes to resume verification with the prior key.
3. Tokens issued under the failed new key will become invalid after rollback because sign/verify stays single-key.

### Post-rotation verification

1. Authenticate to obtain a fresh token (new sign path via `issue_jwt`).
2. Call at least one protected endpoint with the new token and confirm success.
3. Confirm old pre-rotation tokens fail, which proves expected single-key cutover behavior.

## Sequencing Guidance Across Secret Families

1. Rotate Stripe and SES first when possible; these changes are isolated from bearer-token continuity.
2. Rotate JWT last because it has immediate session impact.
3. Run post-rotation verification after each family before proceeding to the next.
