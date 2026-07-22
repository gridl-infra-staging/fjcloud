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
| admin | The admin directory contains API routes for administrative operations, with fully implemented functionality for rate card management (CRUD and customer overrides) and JWT token minting with optional audit logging for impersonation tracking. |
| auth | — |
| indexes | The indexes module provides HTTP route handlers for managing search indexes, including operations for searching, configuring settings, handling suggestions, restoring cold indexes, managing replicas, and tracking metrics. |
| migration | Algolia migration API routes handling source-index discovery, destination eligibility validation, and job management with error-to-code mapping for the migration service. |
| oauth | — |
| storage | The storage module implements S3-compatible object storage with route handlers for bucket and object operations (create, list, get, put, delete, head) across both levels. |
| webhooks | The webhooks module handles inbound webhook events from external services like Stripe, with mod.rs serving as the main router and stripe.rs/stripe_disputes.rs providing specialized event processing for Stripe payments and disputes. |
<!-- [scrai:end] -->
