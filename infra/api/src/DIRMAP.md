<!-- [scrai:start] -->
## src

| File | Summary |
| --- | --- |
| config.rs | Stub summary for infra/api/src/config.rs. |
| errors.rs | Stub summary for errors.rs. |
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
| dns | The dns directory contains Cloudflare DNS integration code. |
| invoicing | I can't locate an invoicing directory in the current repository. |
| middleware | — |
| models | The models directory defines database models and API conversion layers for core domain entities like customers, API keys, rate cards, and Algolia import jobs. |
| provisioner | The provisioner directory implements cloud infrastructure provisioning across multiple providers (AWS, Hetzner, OCI, GCP) with a shared env_config module that centralizes typed environment-variable parsing with consistent validation and error handling. |
| repos | This directory contains data access layer implementations for the fjcloud billing platform, with trait definitions and PostgreSQL-backed repository implementations for domain entities including customers, disputes, usage metering, tenants, webhook events, and Algolia import jobs. |
| router | The router directory implements HTTP middleware (security headers, authentication, rate limiting, CORS) and assembles the API server's route tree, organizing endpoints across auth-limited, tenant, admin, and public paths with optional rate limiting per tenant and role. |
| routes | The routes directory implements HTTP endpoint handlers for an API server, organizing authentication, billing, account management, index operations, S3-compatible storage, and webhook processing (Stripe and AWS SNS) across both standalone route modules and specialized subdirectory owners. |
| secrets | The secrets directory contains AWS credential and secret management functionality, with aws.rs providing AWS-specific secret handling operations. |
| services | The services directory provides core infrastructure and operational services for the fjcloud platform, including audit logging for admin actions, cloud VM provisioning across multiple providers, automated index migration and storage tiering, email delivery, Algolia integration, and metrics-driven load balancing via VM scheduling and health monitoring. |
| startup | The startup directory contains a stub Stripe service implementation that returns `NotConfigured` for all operations when the Stripe secret key is not configured, allowing the API to bootstrap with non-billing functionality while gracefully handling Stripe-dependent requests. |
| stripe | This directory contains Stripe environment configurations for the billing system, with separate modules for live (production) and local (development) Stripe integrations. |
| dns | — |
| invoicing | Handles invoice line item generation and billing calculations, including object storage egress with fractional-cent carryforward logic across billing cycles, metadata tracking, and minimum spend enforcement. |
| middleware | — |
| models | The models directory contains database entity definitions for core business objects like customers, API keys, rate cards, and Algolia import jobs, with conversion logic between database rows and domain models. |
| provisioner | The provisioner directory contains implementations for multiple cloud providers (AWS, Hetzner, OCI, GCP) with a shared env_config module that centralizes typed environment-variable parsing, trimming, and validation across all provisioners. |
| repos | The repos directory contains a data access layer with PostgreSQL-backed repository implementations for domain entities including customers, disputes, usage tracking, webhooks, Algolia imports, tenant management, and index migrations. |
| router | The router module assembles the API's HTTP routes and middleware layers, including authentication and rate limiting handlers, CORS configuration, and route subtrees for billing, account management, index operations, and webhooks. |
| routes | The routes directory implements the HTTP API endpoints for fjcloud's backend, providing handlers for authentication, account management, billing, indexes, storage operations, webhooks, and administrative functions. |
| secrets | The secrets directory contains credential and authentication management code for AWS integration, currently with a stub implementation in aws.rs. |
| services | The services module provides infrastructure operations for the billing and search platform, including index lifecycle management (provisioning, migration, scheduling), external integrations (Algolia, Flapjack search engine, email), and operational oversight (audit logging, health monitoring, webhook delivery, tenant quotas). |
| startup | A stub `StripeService` that returns `NotConfigured` for all operations, extracted to keep `startup.rs` under size limits and enabling the API to bootstrap without Stripe credentials for free-tier signups and admin tools. |
| stripe | The stripe directory contains Stripe integration code with separate modules for live production environment (live.rs) and local development/testing environment (local.rs). |
<!-- [scrai:end] -->
