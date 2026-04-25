# Account Data Policy

## Current Deletion Contract

- `DELETE /account` is a password-confirmed soft-delete flow.
- `DELETE /account` returns `409 Conflict` while the customer still has an active local AllYourBase tenant row.
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

## Export Surface And Not Implemented Boundaries

- Account export is implemented as the authenticated `GET /account/export` profile wrapper, exposed by `export_account` in `infra/api/src/routes/account.rs` and by the settings-page download action `actions.exportAccount` in `web/src/routes/dashboard/settings/+page.server.ts`.
- hard erasure is not implemented.
- downstream cleanup is not implemented.
- retention duration is not yet automated.
