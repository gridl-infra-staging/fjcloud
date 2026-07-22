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
| admin | This directory contains admin API route handlers for infrastructure and billing management, including endpoints for rate cards, customer tokens, deployments, migrations, indexes, and other administrative operations, with audit logging for sensitive actions like impersonation. |
| auth | — |
| indexes | This directory contains HTTP route handlers for managing search indexes in the fjcloud API, including operations for searching, configuring settings, managing documents, handling replicas, import pipelines, lifecycle management, and customer restore functionality for cold indexes. |
| migration | The migration directory provides API routes for Algolia index migration operations, including destination eligibility validation, source index discovery, and job management, with centralized error code mapping for migration-related failures. |
| oauth | — |
| storage | This storage module implements S3-compatible API route handlers for bucket management and object operations, with inline metering for usage tracking. |
| webhooks | Webhooks directory owns webhook route handling and processing for external integrations, primarily Stripe events including dispute handling, along with canonical SNS string tests. |
<!-- [scrai:end] -->
