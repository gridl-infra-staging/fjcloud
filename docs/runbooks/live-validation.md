# Live Credential Validation

Pre-launch validation against real AWS, Stripe, and GitHub credentials.
Run this only after the local-only checklist is complete and before flipping production traffic.

Estimated time: 60–90 minutes.

Before running anything here, complete:

- [`docs/LOCAL_LAUNCH_READINESS.md`](../LOCAL_LAUNCH_READINESS.md)
- [`docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md`](../checklists/LOCAL_SIGNOFF_CHECKLIST.md)

This page is a legacy manual credential-validation guide. For machine-readable
RC/live evidence interpretation, use:

- [`docs/runbooks/paid_beta_rc_signoff.md`](./paid_beta_rc_signoff.md)
- [`docs/runbooks/aws_live_e2e_guardrails.md`](./aws_live_e2e_guardrails.md)

## Prerequisites

Set these in your shell before running anything:

```bash
export STRIPE_SECRET_KEY=sk_test_...
export STRIPE_WEBHOOK_SECRET=whsec_...
export DATABASE_URL=postgres://...
export BACKEND_LIVE_GATE=1
# Optional override when validating a non-default local API port
# (for example `scripts/integration-up.sh` uses `http://localhost:3099`)
# export STRIPE_WEBHOOK_FORWARD_TO=http://localhost:3099/webhooks/stripe
```

Canonical Stripe secret naming is documented in [`docs/env-vars.md`](../env-vars.md#stripe). For staging operator workflows that source a shared secret inventory, use `/Users/stuart/repos/gridl/fjcloud/.secret/.env.secret`.

## 1. AWS + Terraform

Verify AWS auth, then run a drift-check plan against the shared orchestrator module.

```bash
# Verify AWS credentials
aws sts get-caller-identity

# Initialize the shared Terraform module (one-time per workspace)
cd ops/terraform/_shared
terraform init \
  -backend-config="bucket=fjcloud-tfstate-staging" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=fjcloud-tflock"

# Drift-check plan (read-only — do NOT apply without explicit approval)
# Replace <CURRENT_AMI_ID> with the latest Packer-built AMI ID.
terraform plan -var="env=staging" -var="ami_id=<CURRENT_AMI_ID>"
```

Required variables: `env` (staging or prod), `ami_id` (Packer-built AMI).
Optional: `region` (default us-east-1), `domain` (default flapjack.foo),
`db_instance_class`, `api_instance_type`, `alert_emails`.

Pass criteria: `aws sts get-caller-identity` returns a valid ARN and `terraform plan`
reports no unexpected drift (plan output reviewed and confirmed).

## 2. GitHub Actions

```bash
gh auth status
gh run list --limit 20
```

## 3. Stripe + metering

### 3a. Preflight gate (automated checks)

Run the backend gate script to verify Stripe env vars, API key liveness,
webhook forwarding, and metering pipeline state:

In one terminal:
```bash
stripe listen --forward-to "${STRIPE_WEBHOOK_FORWARD_TO:-http://localhost:3001/webhooks/stripe}"
```

In another:
```bash
BACKEND_LIVE_GATE=1 bash scripts/live-backend-gate.sh
```

Pass criteria: exit code 0 and `"passed": true` in the JSON output.

> **Note:** `live-backend-gate.sh` is a preflight check — it validates env vars,
> API key liveness, webhook listener presence, and metering pipeline state.
> It does **not** exercise the checkout, webhook, or invoice flows end-to-end.
> Those require the evidence steps below.

### 3b. Checkout session creation

```bash
stripe checkout sessions create \
  --success-url="https://example.com/success" \
  --cancel-url="https://example.com/cancel" \
  -d "line_items[0][price_data][currency]=usd" \
  -d "line_items[0][price_data][product_data][name]=Stage 7 Validation" \
  -d "line_items[0][price_data][unit_amount]=100" \
  -d "line_items[0][quantity]=1" \
  -d "mode=payment"
```

Pass criteria: returns a checkout session object with `status: "open"` and a valid `url`.

### 3c. Webhook delivery verification

With `stripe listen` running in a separate terminal:

```bash
stripe trigger checkout.session.completed
```

Pass criteria: the `stripe listen` terminal logs a `200` response from the
API webhook handler. If the API is not running, the forwarded event will
return a connection error — this confirms Stripe CLI → local API plumbing.

### 3d. Invoice creation and finalization

```bash
# Create a draft invoice on a test customer
stripe invoices create --customer=<TEST_CUSTOMER_ID>

# Finalize the invoice (triggers PDF generation)
stripe invoices finalize_invoice <INVOICE_ID>

# Verify the invoice has a hosted_invoice_url (PDF delivery)
stripe invoices retrieve <INVOICE_ID>
```

Pass criteria: the finalized invoice has `status: "open"` and a non-empty
`hosted_invoice_url` confirming PDF delivery pipeline works.

## 4. Security audit

```bash
cargo audit -q
```

Expected: 0 vulnerabilities. If any appear, assess and patch before launch.
