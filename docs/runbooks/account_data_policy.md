# Account Data Policy

## Current Deletion Contract

- `DELETE /account` is a password-confirmed soft-delete flow.
- The handler delegates account deletion to `CustomerRepo::soft_delete`.
- Soft delete updates `customers.status = 'deleted'` and retains the customer row.
- retained audit rows are intentional and preserve operator/admin audit context.

## Authentication Behavior After Deletion

- A deleted account cannot authenticate.
- Post-delete login failures return the generic invalid-credentials body exactly as `{"error":"invalid email or password"}`.
- No token or customer-identifying payload is returned on that failure path.

## Admin Visibility Contract

- Admin tenant list and tenant detail views may continue to show deleted customer rows for audit purposes.
- This admin audit visibility is part of the current behavior contract and should be preserved.

## Explicit Not Implemented Boundaries

- Account export is not implemented.
- hard erasure is not implemented.
- downstream cleanup is not implemented.
- retention duration is not yet automated.
