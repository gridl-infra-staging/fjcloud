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
| admin | The admin directory contains API routes for administrative operations, including rate card CRUD and customer overrides, JWT token minting with optional impersonation audit logging, and VM inventory management with local-dev process control. |
| auth | — |
| indexes | The indexes module provides HTTP route handlers for managing search indexes in the fjcloud API, covering index lifecycle, search queries, settings management, document operations, suggestions, replicas, and restore functionality. |
| migration | Handles Algolia search index migrations, providing source-index discovery and destination eligibility validation through dedicated HTTP endpoints. |
| oauth | — |
| storage | This storage directory implements S3-compatible API route handlers for both bucket-level operations (create, list, delete, head) and object-level operations (get, put, delete, head) using path-style routing. |
| webhooks | This directory implements webhook handlers for external integrations, with the main router dispatching incoming webhooks from various sources through private child modules. |
<!-- [scrai:end] -->
