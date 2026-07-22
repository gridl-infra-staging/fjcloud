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
| public_infrastructure.rs | Stub summary for infra/api/src/routes/public_infrastructure.rs. |
| public_site.rs | Stub summary for public_site.rs. |
| version.rs | Stub summary for version.rs. |

| Directory | Summary |
| --- | --- |
| admin | The admin directory contains HTTP route handlers for administrative API operations, including customer JWT token minting with impersonation audit logging, rate card CRUD and customer overrides, and infrastructure management endpoints like deployments, migrations, and indexes. |
| auth | — |
| indexes | The indexes directory contains API route handlers for managing search indexes, including operations for document management, search and suggestions, settings configuration, replica management, lifecycle control, metrics reporting, and customer restore functionality for cold indexes. |
| migration | Migration API surface for Algolia search index migrations, providing endpoints to discover source indexes, validate destination eligibility, manage migration jobs, and report capabilities with stable error code mapping. |
| oauth | — |
| storage | The storage directory implements S3-compatible bucket and object operations via axum route handlers, providing REST endpoints for standard S3 operations including bucket management, object CRUD, and metadata queries with inline metering instrumentation. |
| webhooks | The webhooks module handles incoming webhook events from external services, primarily Stripe payment events and disputes, with a modular architecture that organizes handlers by source. |
<!-- [scrai:end] -->
