# Account Data Policy

## Beta launch policy

- This runbook is the canonical beta policy status owner for account data boundaries; use it to track what is implemented vs. not yet implemented.
- Customer self-service is export-only plus soft-delete:
  - authenticated `GET /account/export` is owned by `infra/api/src/routes/account.rs::export_account` and is triggered from `web/src/routes/dashboard/settings/+page.server.ts::actions.exportAccount`.
  - `DELETE /account` is owned by `infra/api/src/routes/account.rs::delete_account`, which enforces the `CustomerRepo::soft_delete retention boundary` (retained row plus deleted metadata for audit visibility).
- Lifecycle gaps are explicitly status-labeled:
  - hard erasure is implemented (admin-only; see Hard Erasure Contract below).
  - downstream cleanup is handled inline by the hard-erase transaction.
  - retention duration is not yet automated (cron scheduling out of scope; read seam exists).
- Detailed deletion workflow and operator incident guidance remain in `docs/runbooks/account_deletion.md`; this runbook stays the single-source policy status surface.

## Current Deletion Contract

- `DELETE /account` is a password-confirmed soft-delete flow.
- The handler delegates account deletion to `CustomerRepo::soft_delete`.
- On first delete, soft delete updates `customers.status = 'deleted'`, stamps explicit deleted_at metadata, and retains the customer row for audit/retention tracking.
- retained audit rows are intentional and preserve operator/admin audit context.
- The future cleanup read seam is already present via `CustomerRepo::list_deleted_before_cutoff` / `PgCustomerRepo::list_deleted_before_cutoff` to enumerate deleted rows before a retention cutoff.

## Authentication Behavior After Deletion

- A deleted account cannot authenticate.
- Post-delete login failures return the generic invalid-credentials body exactly as `{"error":"invalid email or password"}`.
- No token or customer-identifying payload is returned on that failure path.

## Admin Visibility Contract

- Admin tenant list and tenant detail views may continue to show deleted customer rows for audit purposes.
- This admin audit visibility is part of the current behavior contract and should be preserved.

## Hard Erasure Contract

- `POST /admin/customers/:id/hard-erase` is admin-only (`AdminAuth` required) and writes an `ACTION_CUSTOMER_HARD_ERASE` audit row before erasure.
- Precondition: customer must already be soft-deleted (`status = 'deleted'`). Active or suspended customers are rejected with `400 Bad Request`.
- On success: returns `204 No Content`. The customer row and all dependent data are permanently removed in a single transaction (api_keys, index_replicas, restore_jobs, cold_snapshots, storage_access_keys, storage_buckets, customer_tenants, customer_deployments, customer_rate_overrides, usage_records, usage_daily, audit_log, invoices, then customers; oauth_identities cascades via FK).
- Customers with open (unpaid) invoices are rejected with `409 Conflict` to preserve billing integrity.
- Repeat calls for an already-erased or unknown customer return `404 Not Found`.
- Owner: `CustomerRepo::hard_delete` in `infra/api/src/repos/pg_customer_repo.rs`, handler in `infra/api/src/routes/admin/tenants.rs::hard_erase_customer`.

## Retention Sweep Entrypoint

- `CustomerRepo::list_deleted_before_cutoff(cutoff: DateTime<Utc>)` returns soft-deleted customers whose `deleted_at` predates the cutoff, ordered oldest-first.
- An operator or future cron job calls `list_deleted_before_cutoff` to enumerate candidates, then calls `POST /admin/customers/:id/hard-erase` for each.
- Cron automation is not yet implemented; the read seam and erase endpoint are the building blocks.

## Export Surface

- Account export is implemented as the authenticated `GET /account/export` profile wrapper, exposed by `export_account` in `infra/api/src/routes/account.rs` and by the settings-page download action `actions.exportAccount` in `web/src/routes/dashboard/settings/+page.server.ts`.
