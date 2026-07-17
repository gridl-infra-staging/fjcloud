# Stage 4 Stripe Restricted Key Scope Audit

## Purpose
Stage 4 produces the canonical least-privilege Stripe scope matrix for restricted key creation in Stage 5. This artifact inventories Stripe consumers, maps explicit `None|Read|Write` decisions, and records reproducible `file:line` evidence.

## Command Provenance
- UTC stamp: `20260428T201509Z`
- Repository root: `fjcloud_dev`
- Grouped discovery command executed at stamp above:
  - `rg -n "stripe::|/v1/|stripe " infra/api/src infra/api/tests scripts`
- Timestamped raw output reference:
  - `docs/runbooks/evidence/secret-rotation/20260428T201509Z_stripe_restricted/grouped_rg_output.txt`

## Runtime/Test/Shell Consumer Inventory (Stage 4 scope)

### Rust runtime owners (`infra/api/src/stripe/live.rs`)
- `create_customer` -> `Customer::create` (`infra/api/src/stripe/live.rs:167`, `:172`) => `Customers` write.
- `create_setup_intent` -> `SetupIntent::create` (`infra/api/src/stripe/live.rs:181`, `:189`) => `SetupIntents` write.
- `create_billing_portal_session` -> `BillingPortalSession::create` (`infra/api/src/stripe/live.rs:199`, `:211`) => `Billing Portal` write (session creation).
- `list_payment_methods` -> `Customer::retrieve` + `PaymentMethod::list` (`infra/api/src/stripe/live.rs:220`, `:229`, `:242`) => `Customers` read + `PaymentMethods` read.
- `detach_payment_method` -> `PaymentMethod::detach` (`infra/api/src/stripe/live.rs:264`, `:269`) => `PaymentMethods` write.
- `set_default_payment_method` -> `Customer::update` (`infra/api/src/stripe/live.rs:278`, `:293`) => `Customers` write.
- `create_and_finalize_invoice` -> `InvoiceItem::create` + `Invoice::create` (`infra/api/src/stripe/live.rs:302`, `:320`, `:336`) => `Invoice Items` write + `Invoices` write.
- `create_checkout_session` -> `CheckoutSession::create` (`infra/api/src/stripe/live.rs:390`, `:418`) => `Checkout Sessions` write.
- `retrieve_subscription` -> `Subscription::retrieve` (`infra/api/src/stripe/live.rs:430`, `:440`) => `Subscriptions` read.
- `cancel_subscription` -> `Subscription::update|cancel` (`infra/api/src/stripe/live.rs:449`, `:464`, `:470`) => `Subscriptions` write.
- `update_subscription_price` -> `Subscription::retrieve|update` (`infra/api/src/stripe/live.rs:480`, `:494`, `:512`) => `Subscriptions` read+write.

### Rust live-test owners (`infra/api/tests/common/live_stripe_helpers.rs`)
- `validate_stripe_key_live` -> `Balance::retrieve` (`infra/api/tests/common/live_stripe_helpers.rs:75`, `:87`) => `Balance` read.
- `attach_test_payment_method` (`:100`, `:102`) and `attach_declining_payment_method` (`:116`, `:118`) -> `PaymentMethod::attach` => `PaymentMethods` write.
- Webhook probe path (`validate_stripe_webhook_delivery`) calls runtime service methods (`create_customer`, `set_default_payment_method`, `create_and_finalize_invoice`) and depends on live webhook delivery (`infra/api/tests/common/live_stripe_helpers.rs:134-231`).
- Stage 6 dependency note: Stage 6 validation reuses these same live capabilities for auth and webhook-path verification.

### Shell owners (canonical `STRIPE_SECRET_KEY` path)
- `scripts/lib/stripe_checks.sh::check_stripe_key_live` calls `GET https://api.stripe.com/v1/balance` (`scripts/lib/stripe_checks.sh:82`, `:101`) => `Balance` read.
- `scripts/validate-stripe.sh` executes:
  - `POST /v1/customers` (`scripts/validate-stripe.sh:122`)
  - `POST /v1/payment_methods/pm_card_visa/attach` (`:140`)
  - `POST /v1/customers/$CUSTOMER_ID` update default PM (`:157`)
  - `POST /v1/invoiceitems` (`:169`)
  - `POST /v1/invoices` (`:180`)
  - `POST /v1/invoices/$INVOICE_ID/pay` (`:197`)
- `scripts/live-backend-gate.sh` includes `check_stripe_key_live` in required check order (`scripts/live-backend-gate.sh:501-504`).
- `scripts/staging_billing_rehearsal.sh` delegates to `lib/staging_billing_rehearsal_impl.sh` and mutation helpers (`scripts/staging_billing_rehearsal.sh:22-27`).
- `scripts/staging_billing_dry_run.sh` validates allowed key prefixes and webhook secret presence (`scripts/staging_billing_dry_run.sh:146-178`) but does not call Stripe API endpoints.

## Scope Matrix
| resource | dashboard label | decision (None/Read/Write) | evidence (file:line) | rationale | stage6_probe_target (yes/no) |
|---|---|---|---|---|---|
| Balance | Balance | Read | `scripts/lib/stripe_checks.sh:82,101`; `infra/api/tests/common/live_stripe_helpers.rs:75,87` | Required for live key authentication checks in gate/tests. | no |
| Customers | Customers | Write | `infra/api/src/stripe/live.rs:167,172,278,293`; `scripts/validate-stripe.sh:122,157` | Runtime customer creation/update and validation script customer lifecycle. | no |
| Payment Methods | Payment methods | Write | `infra/api/src/stripe/live.rs:242,264,269`; `infra/api/tests/common/live_stripe_helpers.rs:100,102,116,118`; `scripts/validate-stripe.sh:140` | Runtime/test attach/list/detach and default PM workflows. | no |
| Setup Intents | Setup Intents | Write | `infra/api/src/stripe/live.rs:181,189` | Frontend card setup flow depends on setup intent creation. | no |
| Billing Portal | Billing portal | Write | `infra/api/src/stripe/live.rs:199,211` | Runtime creates customer billing portal sessions. | no |
| Invoice Items | Invoice items | Write | `infra/api/src/stripe/live.rs:302,320`; `scripts/validate-stripe.sh:169` | Invoice line item creation required before invoice creation/finalization. | no |
| Invoices | Invoices | Write | `infra/api/src/stripe/live.rs:336`; `scripts/validate-stripe.sh:180,197` | Runtime creates invoices; validation script pays invoice to verify end-to-end billing readiness. | no |
| Checkout Sessions | Checkout Sessions | Write | `infra/api/src/stripe/live.rs:390,418` | Runtime checkout creation endpoint requires write access. | no |
| Subscriptions | Subscriptions | Write | `infra/api/src/stripe/live.rs:430,440,449,464,470,480,494,512` | Runtime retrieves/cancels/updates subscriptions, including price changes. | no |
| Refunds | Refunds | None | `docs/runbooks/evidence/secret-rotation/20260428T201509Z_stripe_restricted/grouped_rg_output.txt` (no hits in Stage 4 named owners) | Not used in current staging rehearsal or Stage 4 named runtime/test/shell owners; omit and deny-probe in Stage 6. | yes |
| Payouts | Payouts | None | `docs/runbooks/evidence/secret-rotation/20260428T201509Z_stripe_restricted/grouped_rg_output.txt` (no hits in Stage 4 named owners) | Platform payout operations are out of current staging billing workflow; keep denied. | yes |
| Disputes | Disputes | None | `docs/runbooks/evidence/secret-rotation/20260428T201509Z_stripe_restricted/grouped_rg_output.txt` (no hits in Stage 4 named owners) | No dispute workflows in runtime/test/shell owners for this stage. | yes |

## Discovery Reconciliation
Grouped `rg` output includes additional Stripe references outside Stage 4 owner set. Reconciliation result:
- Mapped to matrix rows:
  - `infra/api/src/stripe/live.rs` -> Customers, Setup Intents, Billing Portal, Payment Methods, Invoice Items, Invoices, Checkout Sessions, Subscriptions.
  - `infra/api/tests/common/live_stripe_helpers.rs` -> Balance, Payment Methods, Customers, Invoices via runtime service calls.
  - `scripts/lib/stripe_checks.sh` -> Balance.
  - `scripts/validate-stripe.sh` -> Customers, Payment Methods, Invoice Items, Invoices.
  - `scripts/live-backend-gate.sh` -> Balance check invocation via `check_stripe_key_live`.
  - `scripts/staging_billing_rehearsal.sh` and `scripts/staging_billing_dry_run.sh` -> orchestration/config guards for same resources.
- Explicit exclusions (out of Stage 4 named-owner scope):
  - `scripts/stripe/*.sh` catalog/portal account provisioning scripts.
  - `scripts/canary/customer_loop_synthetic.sh` canary path.
  - `scripts/lib/staging_billing_rehearsal_reset.sh` reset helper and `scripts/tests/*` fixtures.
  - Non-Stripe `/api/v1/` hits (Mailpit/API endpoints) and `stripe::` type imports without API calls.

No unresolved grouped-discovery hits remain for Stage 4 scope: every in-scope owner hit is mapped, and all others are explicitly excluded with rationale.

## Coverage Check
Confirmed represented by at least one table row:
- `scripts/validate-stripe.sh` -> Customers, Payment Methods, Invoice Items, Invoices.
- `scripts/lib/stripe_checks.sh::check_stripe_key_live` -> Balance.
- `scripts/live-backend-gate.sh` -> Balance (through check invocation).
- `scripts/staging_billing_rehearsal.sh` / `scripts/staging_billing_dry_run.sh` -> key/webhook gating for same resource set.
- `infra/api/src/stripe/live.rs` named owners -> rows present.
- `infra/api/tests/common/live_stripe_helpers.rs` named owners -> Balance/Payment Methods/Customers/Invoices rows present.

## Automated Verification Commands and Status
- `rg -n "check_stripe_key_live|validate_stripe_key_live|stripe::|/v1/|stripe " infra/api/src infra/api/tests scripts`
  - Status: passed (exit 0); output captured in `grouped_rg_output.txt`.
- `test -s "$EVIDENCE_DIR/scopes_audit.md"`
  - Status: passed (non-empty file).
