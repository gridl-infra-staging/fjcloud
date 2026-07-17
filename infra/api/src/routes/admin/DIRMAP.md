<!-- [scrai:start] -->
## admin

| File | Summary |
| --- | --- |
| broadcast.rs | Stub summary for infra/api/src/routes/admin/broadcast.rs. |
| indexes.rs | Stub summary for infra/api/src/routes/admin/indexes.rs. |
| invoices.rs | Stub summary for invoices.rs. |
| migrations.rs | Stub summary for infra/api/src/routes/admin/migrations.rs. |
| mod.rs | Stub summary for mod.rs. |
| rate_cards.rs | Admin rate card routes: CRUD and customer override management. |
| tenants.rs | Stub summary for tenants.rs. |
| tokens.rs | `POST /admin/tokens` — mint a JWT for a given customer.



Adds an optional `purpose` discriminator: when set to "impersonation",

the handler writes an `audit_log` row so there's a durable trail of

who impersonated whom and when. |
| vms.rs | Admin VM inventory endpoints: list, detail, and local-mode process kill.



The kill endpoint is local-dev-only: it sends SIGTERM to the Flapjack process

bound to a VM's port. |
<!-- [scrai:end] -->
