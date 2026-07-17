# Staging Billing Rehearsal Runbook

Guarded staging billing rehearsal runbook for the real-credential evidence lane.

This runbook documents the implemented rehearsal runner in `scripts/staging_billing_rehearsal.sh` and its step owners in `scripts/lib/staging_billing_rehearsal_flow.sh`.

## Purpose

- Reuse the existing billing pipeline and owner scripts instead of creating a parallel staging flow.
- Run a deterministic rehearsal with machine-readable artifacts for every required step.
- Fail closed when live mutation prerequisites or evidence convergence are missing.

## Non-Goals

- Do not provision Stripe secrets, Stripe products, or Terraform resources from this runbook.
- Do not run manual QA checks outside reproducible CLI commands.
- Do not treat this as a replacement for canonical dated infrastructure evidence in `docs/runbooks/staging-evidence.md`.

## Required Environment Variables

See `docs/env-vars.md` for canonical variable definitions.

Base preflight inputs:

- `STAGING_API_URL`
- `STAGING_STRIPE_WEBHOOK_URL`
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`

Guarded live-mutation rehearsal inputs (in addition to base preflight inputs):

- `ADMIN_KEY`
- One DB evidence URL:
  - `DATABASE_URL`, or
  - `INTEGRATION_DB_URL`
- `MAILPIT_API_URL` only when runtime email evidence is expected from a Mailpit sink

## Dedicated Env File Example

Create a dedicated shell-safe env file outside git.

```bash
ENV_FILE="${TMPDIR:-/tmp}/fjcloud-staging-billing-rehearsal.env"
umask 077
cat > "$ENV_FILE" <<'EOF'
STAGING_API_URL=https://api.flapjack.foo
STAGING_STRIPE_WEBHOOK_URL=https://api.flapjack.foo/webhooks/stripe
STRIPE_SECRET_KEY=sk_test_REDACTED
STRIPE_WEBHOOK_SECRET=whsec_REDACTED
ADMIN_KEY=REDACTED
DATABASE_URL=postgres://REDACTED@host:5432/fjcloud
# or INTEGRATION_DB_URL=postgres://REDACTED@host:5432/fjcloud
# MAILPIT_API_URL=http://127.0.0.1:8025   # only when runtime uses Mailpit
EOF
chmod 600 "$ENV_FILE"
```

Blocker and preflight rehearsal (no live billing mutation attempted):

```bash
bash scripts/staging_billing_rehearsal.sh \
  --env-file "${TMPDIR:-/tmp}/fjcloud-staging-billing-rehearsal.env"
```

Guarded live mutation rehearsal:

```bash
bash scripts/staging_billing_rehearsal.sh \
  --env-file "${TMPDIR:-/tmp}/fjcloud-staging-billing-rehearsal.env" \
  --month 2026-04 \
  --confirm-live-mutation
```

## Fixed Artifact Tree

Each run writes a deterministic artifact directory:

```text
${TMPDIR:-/tmp}/fjcloud_staging_billing_rehearsal_<YYYYmmddTHHMMSSZ>_<pid>/
  summary.json
  steps/
    preflight.json
    health.json                     (only when preflight passes and health is reached)
    metering_evidence.json
    live_mutation_guard.json
    live_mutation_attempt.json
  billing_run.json
  invoice_rows.json
  webhook.json
  invoice_email.json
```

The runner creates the artifact directory tree with owner-only permissions
(`700` directories, `600` files) because the evidence payloads can include
invoice IDs, customer emails, and other sensitive operator context.

## What The Rehearsal Verifies

- `preflight` step delegates to `bash scripts/staging_billing_dry_run.sh --check --env-file <path>`.
- `metering_evidence` step runs `check_usage_records_populated` and `check_rollup_current`.
- `live_mutation_guard` enforces `--month`, `--confirm-live-mutation`, `ADMIN_KEY`, and DB evidence URL preconditions.
- `live_mutation_attempt` performs billing mutation via `POST /admin/billing/run` only after guard success.
- Evidence convergence then validates DB invoice rows and billing-run Stripe webhook processing before reporting success.

## Failure Classification Model

The runner emits top-level `result`, `classification`, `detail`, `artifact_dir`, and per-step artifacts.

Step ownership and typical classification families:

- Preflight owner (`staging_billing_dry_run.sh --check`): env/config contract failures.
- Metering evidence owner: stale or missing `usage_records` or rollup evidence.
- Live mutation guard owner: missing month/confirmation/admin key/db URL preconditions.
- Live mutation and evidence owners: billing call failures, invoice row query failures, webhook non-convergence, or runtime email evidence non-convergence.

Use `summary.json` as the single run-level truth and inspect step/evidence JSON files for exact failure detail.

## Current Blocker Verification (Read-Only)

Recheck env/config blockers without mutation:

```bash
bash scripts/staging_billing_dry_run.sh --check --env-file <dedicated-env-file>
```

Recheck public health endpoint:

```bash
curl -fsS https://api.flapjack.foo/health
```

Recheck staging SSM parameter presence without printing values:

```bash
aws ssm get-parameters \
  --names \
    /fjcloud/staging/admin_key \
    /fjcloud/staging/database_url \
    /fjcloud/staging/stripe_secret_key \
    /fjcloud/staging/stripe_webhook_secret \
  --query '{found:Parameters[].Name,missing:InvalidParameters}' \
  --output json
```

For dated infrastructure status (DNS cutover, ACM, SES, public health), use `docs/runbooks/staging-evidence.md`. If facts are refreshed, update that canonical evidence file in the same change instead of duplicating blocker history here.

## Email Evidence Contract

- Code-level invoice-ready email attempts are validated in `infra/api/tests/invoice_email_test.rs`.
- Runtime service selection in `infra/api/src/startup.rs` selects `MailpitEmailService` only when `MAILPIT_API_URL` is configured in local/dev noop mode; otherwise that local/dev path falls back to `NoopEmailService`, while SES-mode startup selects `SesEmailService`.
- Best-effort (non-blocking) invoice-ready send semantics are implemented in `infra/api/src/invoicing/stripe_sync.rs` via `send_invoice_ready_email_best_effort`.
- Delivery transports for SES and the local Mailpit sink are implemented in `infra/api/src/services/email.rs`.
- Rehearsal runtime email evidence in `scripts/lib/staging_billing_rehearsal_email_evidence.sh` fails closed as `invoice_email_evidence_delegated` when `MAILPIT_API_URL` is not available on SES-backed staging.
- Live SES delivery proof for that delegated staging path is owned by the SES deliverability wrapper in `scripts/launch/ses_deliverability_evidence.sh`.
- SES inbox-delivery closure for delegated staging runs is owned by `docs/runbooks/email-production.md` plus `scripts/launch/ses_deliverability_evidence.sh`; the billing rehearsal does not claim inbox-delivery closure when Mailpit is absent.
