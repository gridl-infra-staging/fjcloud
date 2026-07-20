<!-- [scrai:start] -->
## routes

| File | Summary |
| --- | --- |
| account.rs | Stub summary for account.rs. |
| auth.rs | Stub summary for infra/api/src/routes/auth.rs. |
| billing.rs | Stub summary for billing.rs. |
| browser_error_reporting.rs | Stub summary for browser_error_reporting.rs. |
| migration.rs | Stub summary for infra/api/src/routes/migration.rs. |
| oauth.rs | Stub summary for oauth.rs. |
| onboarding.rs | Stub summary for onboarding.rs. |
| public_site.rs | Stub summary for public_site.rs. |
| version.rs | Stub summary for version.rs. |

| Directory | Summary |
| --- | --- |
| admin | Admin routes for internal operations including JWT token minting with optional audit logging for impersonation, rate card CRUD with customer overrides, and administrative endpoints for deployments, migrations, tenants, VMs, and related infrastructure management. |
| auth | — |
| indexes | This directory contains HTTP route handlers for index operations in the Algolia-based search platform, including lifecycle management, search, settings, suggestions, document handling, replicas, customer restore functionality, and import engine integration. |
| migration | HTTP route handlers for Algolia index migrations, including source-index discovery, destination eligibility validation, and job management. |
| oauth | — |
| storage | This directory implements S3-compatible storage handlers for bucket and object operations, with mod.rs defining the HTTP route table and objects.rs handling object-level endpoints with integrated usage metering. |
| webhooks | The webhooks directory handles incoming webhook routing and processing for external services, with specialized handlers for Stripe events including disputes. |
<!-- [scrai:end] -->
