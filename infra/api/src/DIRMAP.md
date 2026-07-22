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
| dns | The dns directory contains Cloudflare DNS integration code, specifically a cloudflare.rs module for interacting with Cloudflare's DNS services. |
| invoicing | The invoicing directory handles invoice line item management and represents core billing functionality for the fjcloud platform. |
| middleware | — |
| models | The models directory contains database entity definitions and API conversion layers for core domain objects including customers, API keys, index migrations, replicas, rate cards, and Algolia import jobs, with a dedicated submodule providing validation logic and state-tracking structures for managing search index import operations. |
| provisioner | The provisioner directory contains multi-cloud infrastructure provisioning implementations for AWS, Hetzner, and other providers, with a shared env_config module that centrally handles typed environment-variable parsing, trimming, and validation across all provisioners. |
| repos | The repos directory contains a collection of Postgres-backed repository implementations for managing core domain entities in the billing platform, including customers, invoices, disputes, Algolia import jobs, index migrations, VMs, webhooks, and usage data. |
| router | The router directory implements the HTTP routing layer and middleware for the Axum API server, including rate limiting (auth, tenant, admin, S3), security headers, CORS, JWT authentication, and route assembly that merges all endpoint subtrees (auth, billing, indexes, migrations, webhooks, etc.) with optional middleware layers. |
| routes | The routes module contains HTTP endpoint handlers for the API server, organizing functionality across authentication, billing, search indexes, admin operations, webhooks, and object storage. |
| secrets | The secrets directory contains credential and authentication management code, with AWS-specific secrets handling in aws.rs. |
| services | The services module provides the operational backbone for fjcloud's API, including audit logging for sensitive admin actions, transactional email delivery, VM provisioning across multiple cloud providers, metrics-based scheduler for index load balancing, and background systems for cold storage archival, replication, and webhook management. |
| startup | This module provides a stub Stripe service implementation that returns `NotConfigured` for all operations, enabling the API to bootstrap and handle free-tier signups and admin functions when the `STRIPE_SECRET_KEY` environment variable is not configured. |
| stripe | The stripe directory contains Stripe integration code for different environments, with separate modules for live production and local development Stripe configurations. |
<!-- [scrai:end] -->
