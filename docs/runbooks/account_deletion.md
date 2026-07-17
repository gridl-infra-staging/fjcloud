# Account Deletion — Soft vs Hard

**Status:** soft-delete shipped. Hard erasure (T2.2) not yet shipped — see plan rev 4 [apr26_3pm_1_operator_tooling_gaps_pre_beta.md](../../chats/apr26_3pm_1_operator_tooling_gaps_pre_beta.md) T2.2.

## Two distinct operations

The codebase has two related but separate "delete a customer" concepts. Confusing them is a customer-trust hazard — please read this whole doc before changing either endpoint.

### Soft-delete (live today)

**What it does:** flips `customers.status='deleted'`, stamps `customers.deleted_at=NOW()`, leaves all other rows in place.

**What it does NOT do:** does NOT cancel Stripe subscriptions, does NOT delete S3 objects, does NOT remove Garage indexes, does NOT remove email-derived PII from billing aggregates.

**Effect on auth:** the auth gates ([auth/tenant.rs](../../infra/api/src/auth/tenant.rs), [auth/api_key.rs](../../infra/api/src/auth/api_key.rs), [services/storage/s3_auth.rs](../../infra/api/src/services/storage/s3_auth.rs)) all delegate to [`customer_auth_state` in models/customer.rs](../../infra/api/src/models/customer.rs#L16-L23). Soft-deleted customers (`status='deleted'`) map to `CustomerAuthState::Missing`, which the gates render as 401 InvalidToken. **A soft-deleted customer cannot make any further authenticated requests.**

**Endpoints:**
- `DELETE /account` (self-serve, requires password) — [routes/account.rs:229-251](../../infra/api/src/routes/account.rs#L229-L251).
- `DELETE /admin/tenants/:id` (admin override) — [routes/admin/tenants.rs:235-246](../../infra/api/src/routes/admin/tenants.rs#L235-L246).

**Is it reversible?** Yes — until the hard-erasure window elapses (today: never, since hard-erasure isn't shipped). To reactivate a soft-deleted customer, an operator can `UPDATE customers SET status='active', deleted_at=NULL WHERE id=...`. After T2.2 lands the reversal window will be ~7 days.

### Hard erasure (T2.2 — NOT YET SHIPPED)

**What it WILL do once shipped:**
- Cancel Stripe subscription (so we stop charging the card).
- Delete S3 / Garage objects belonging to the customer's tenants.
- Remove email and identifiable fields from `customers` (tombstone the row).
- Retain only anonymized billing aggregates per regulatory record-keeping requirements.

**Why two separate operations?** GDPR Art. 17 + similar regimes have a 7-day grace window during which the customer can reverse the deletion. Soft-delete satisfies the immediate "stop processing" requirement (auth blocked, billing freezes); hard-erasure runs as a delayed batch.

## Test coverage

| Behavior | Test | Status |
|---|---|---|
| `soft_delete` flips `status` AND stamps `deleted_at` | [pg_customer_repo_test.rs::soft_delete_retains_row_and_is_idempotent](../../infra/api/tests/pg_customer_repo_test.rs#L214) | shipped |
| Auth gate maps `status='deleted'` → `Missing` (401) | [models::customer::tests::customer_auth_state_deleted_status_is_missing](../../infra/api/src/models/customer.rs) | shipped (T0.3) |
| Auth gate distinguishes `Suspended` (403) from `Missing` (401) | [models::customer::tests::customer_auth_state_suspended_status_is_suspended](../../infra/api/src/models/customer.rs) | shipped (T0.3) |
| Hard erasure flow | not implemented | T2.2 follow-up |

The first two together pin the **complete soft-delete contract** discriminatingly. A regression in either layer fails the corresponding test:

- A `soft_delete` that flips only one of the two columns fails the pg_customer_repo test.
- A `customer_auth_state` that lets `status='deleted'` through fails the auth-state test (security regression).
- A `customer_auth_state` that always returns Missing would pass the deleted test but fail the active and suspended tests.

## Operator workflow during incident response

Today, suspending a customer does NOT require deletion. Use:

| Goal | Endpoint | Reversibility |
|---|---|---|
| Pause billing + auth temporarily (e.g. fraud investigation) | `POST /admin/customers/:id/suspend` | Reactivable via `/reactivate` |
| Customer requested account closure (self-serve UX) | `DELETE /account` (customer-driven) | Reversible until T2.2 hard erasure |
| GDPR Art. 17 deletion request | `DELETE /admin/tenants/:id` (today, soft-delete only) | Reversible — but hard erasure is the regulatory satisfier; T2.2 closes that gap |

## What to NEVER do

- **Don't** UPDATE `customers.status` directly to bypass the soft_delete path. The soft_delete SQL also stamps `deleted_at` and `updated_at` together, which the audit-trail and reaper queries rely on.
- **Don't** add a "skip auth gate for deleted customers" path. The deleted→Missing→401 chain is the reason customer-facing soft-delete is safe.
- **Don't** conflate soft-delete with hard-erasure in tests. T0.3's tests scope-limit to current behavior; the Stripe-cancel-on-delete assertion belongs in T2.2 only.
