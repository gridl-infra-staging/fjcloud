<!-- [scrai:start] -->
## admin

| File | Summary |
| --- | --- |
| alerts.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/admin/alerts.rs. |
| broadcast.rs | Stub summary for broadcast.rs. |
| deployments.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/admin/deployments.rs. |
| indexes.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_1_frontend_test_suite/fjcloud_dev/infra/api/src/routes/admin/indexes.rs. |
| invoices.rs | Stub summary for invoices.rs. |
| migrations.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/admin/migrations.rs. |
| mod.rs | Stub summary for mod.rs. |
| providers.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/admin/providers.rs. |
| rate_cards.rs | Admin rate card routes: CRUD and customer override management. |
| tenants.rs | Stub summary for tenants.rs. |
| tokens.rs | `POST /admin/tokens` — mint a JWT for a given customer.



Adds an optional `purpose` discriminator: when set to "impersonation",

the handler writes an `audit_log` row so there's a durable trail of

who impersonated whom and when. |
| usage.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/admin/usage.rs. |
| vms.rs | Admin VM inventory endpoints: list, detail, and local-mode process kill.



The kill endpoint is local-dev-only: it sends SIGTERM to the Flapjack process

bound to a VM's port. |
<!-- [scrai:end] -->
