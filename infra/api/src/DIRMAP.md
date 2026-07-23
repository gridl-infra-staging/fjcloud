<!-- [scrai:start] -->
## src

| File | Summary |
| --- | --- |
| config.rs | Stub summary for infra/api/src/config.rs. |
| errors.rs | Stub summary for infra/api/src/errors.rs. |
| helpers.rs | Stub summary for helpers.rs. |
| invoicing.rs | Stub summary for invoicing.rs. |
| main.rs | Stub summary for infra/api/src/main.rs. |
| router.rs | Stub summary for infra/api/src/router.rs. |
| scopes.rs | Auth vocabulary for the Flapjack Cloud platform.



**Management scopes** govern what a customer's API key can do on the Flapjack Cloud

management API. |
| startup.rs | Startup phase helpers — each function owns one logical phase of server

bootstrap, called in sequence by main(). |
| startup_env.rs | Stub summary for startup_env.rs. |
| startup_repos.rs | Repository initialization extracted from main startup. |
| state.rs | Stub summary for infra/api/src/state.rs. |
| usage.rs | Stub summary for usage.rs. |

| Directory | Summary |
| --- | --- |
| auth | — |
| dns | — |
| invoicing | Constructs invoice line items for billing, with specialized handling for object storage egress charges that carries forward fractional cents to the next billing cycle. |
| middleware | — |
| models | The models directory contains database entity definitions and API conversion layers for the fjcloud platform, including representations for customers, API keys, rate cards, index replicas, migrations, and Algolia import operations. |
| provisioner | The provisioner directory contains cloud infrastructure provisioning implementations for multiple vendors (AWS, GCP, OCI, Hetzner) along with shared utilities for environment configuration parsing. |
| repos | This directory contains repository/data access layer implementations for the fjcloud backend, primarily PostgreSQL-backed modules handling customer accounts, billing (invoices, disputes), usage metering, VM infrastructure, webhooks, and Algolia search integration. |
| router | The router module composes the HTTP API structure by assembling Axum middleware (security headers, rate limiting, CORS, S3 authentication) and route definitions across auth, billing, indexes, analytics, migrations, and tenant management. |
| routes | — |
| secrets | — |
| services | — |
| startup | A Stripe configuration module providing a stub service that returns `NotConfigured` for all operations when the `STRIPE_SECRET_KEY` is not set, allowing the API to bootstrap and handle Stripe-dependent requests gracefully. |
| stripe | — |
<!-- [scrai:end] -->
