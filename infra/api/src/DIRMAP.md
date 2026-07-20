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
| usage.rs | Stub summary for usage.rs. |

| Directory | Summary |
| --- | --- |
| auth | — |
| dns | — |
| invoicing | The invoicing directory contains billing and invoice generation logic for the fjcloud platform. |
| middleware | — |
| models | Database models and API conversion layers for core platform entities including customers, API keys, rate cards, and index migrations. |
| provisioner | The provisioner directory contains cloud provider-specific provisioning implementations (AWS, Hetzner, OCI, GCP) with a centralized env_config module that provides typed, validated environment variable parsing for all provisioners. |
| repos | The repos directory contains the data access layer for the fjcloud API, implementing PostgreSQL-backed repository modules for managing core entities like customers, tenants, disputes, usage metrics, and Algolia import jobs with separate concerns for lifecycle management and query operations. |
| router | The router directory manages HTTP middleware (security headers, rate limiting, S3 authentication, CORS) and assembles all API routes into a single Axum router with appropriate middleware layers applied to different route groups (auth-limited, tenant-authenticated, admin). |
| routes | The routes directory contains HTTP endpoint handlers for the fjcloud API server, including authentication, account management, billing, Algolia search index operations, S3-compatible storage, webhook processing, and administrative functions like rate card management and tenant provisioning. |
| secrets | The secrets directory contains AWS credential and secret management functionality. |
| services | The services module contains business-logic layers for the Rust API backend, including audit logging, email delivery, search-engine integration (Algolia/Flapjack), infrastructure provisioning, VM scheduling and load balancing, index lifecycle management, cold-storage tiering, webhooks, and health monitoring. |
| startup | Stub Stripe service implementation that returns `NotConfigured` for all operations when the `STRIPE_SECRET_KEY` environment variable is not set, allowing the API to bootstrap with limited functionality. |
| stripe | This directory contains Stripe environment-specific configuration and client initialization—live.rs for production Stripe and local.rs for local/testing environments. |
<!-- [scrai:end] -->
