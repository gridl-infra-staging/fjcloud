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
| admin | The admin routes module provides internal administrative endpoints for managing billing-related resources including rate cards, customer tokens (with audit-logged impersonation), VM inventory, invoices, and tenants. |
| auth | — |
| indexes | Route handlers for index management including search, settings, suggestions, document operations, and lifecycle management. |
| oauth | — |
| storage | The storage directory implements S3-compatible route handlers for bucket and object lifecycle operations (list, create, read, write, delete) with path-style addressing. |
| webhooks | The webhooks directory handles incoming webhook events, primarily from Stripe (including dispute handling) and AWS SNS, organized through a central route owner with per-source private child modules. |
| admin | The admin directory provides administrative API routes for managing rate cards, customer tokens with audit logging for impersonation, and VM inventory. |
| auth | — |
| indexes | This directory contains route handlers for index management in the API, covering search, settings, suggestions, lifecycle, restore operations for cold indexes, replicas, and Algolia document import functionality. |
| oauth | — |
| storage | S3-compatible storage API implementing bucket and object operations (create, list, delete, get, put, head) via path-style routing, with object handlers including inline metering instrumentation. |
| webhooks | The webhooks directory handles incoming webhook events from external services, with specialized modules for processing Stripe webhooks and Stripe dispute events. |
<!-- [scrai:end] -->
