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
| dns | The dns directory contains DNS-related functionality, including a Cloudflare integration module (currently a stub implementation). |
| invoicing | The invoicing directory contains Rust code for handling billing line items, likely supporting invoice generation and line-item management within the billing system. |
| middleware | — |
| models | The models directory contains database entity definitions and API conversion layers for core domain objects including customers, API keys, rate cards, and index migrations. |
| provisioner | The provisioner directory contains cloud provider-specific implementations (AWS, Hetzner, OCI, GCP) for infrastructure provisioning, with a shared env_config module providing centralized, consistent environment-variable parsing and validation across all provisioners. |
| repos | This directory contains Postgres-backed repository implementations for the fjcloud backend, providing data access and persistence layers for domain objects including jobs, disputes, migrations, tenants, webhooks, customers, and usage tracking. |
| router | The router directory contains middleware handlers for authentication, rate limiting, security headers, CORS validation, and S3 signature verification, along with functions that assemble the complete HTTP router by composing route subtrees (auth-limited, tenant, admin, webhooks, internal, and v1 routes) with optional rate-limiting layers. |
| routes | The routes directory contains HTTP API endpoint handlers for the application, organized into route modules covering user authentication, account management, billing, search indexes, S3-compatible storage operations, admin functions, and webhook integrations. |
| secrets | The secrets directory contains AWS-related credential and configuration management code. |
| services | The services module contains specialized business logic and infrastructure services for the fjcloud API, including audit logging for admin actions, email transactionalization, search index lifecycle management (cold storage archival), VM provisioning and load balancing via the scheduler, webhook handling, and integration with the Flapjack search engine. |
| startup | The startup directory contains a stub Stripe service implementation used when Stripe is not configured, allowing the API to bootstrap and serve free-tier signups and admin tooling without requiring Stripe credentials. |
| stripe | The stripe directory contains Rust modules for Stripe payment processing with separate implementations for production (live.rs) and local development (local.rs) environments. |
<!-- [scrai:end] -->
