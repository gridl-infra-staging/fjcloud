<!-- [scrai:start] -->
## src

| File | Summary |
| --- | --- |
| config.rs | Stub summary for config.rs. |
| errors.rs | Stub summary for errors.rs. |
| helpers.rs | Stub summary for helpers.rs. |
| invoicing.rs | Stub summary for invoicing.rs. |
| main.rs | Stub summary for main.rs. |
| router.rs | Stub summary for router.rs. |
| scopes.rs | Auth vocabulary for the Flapjack Cloud platform.



**Management scopes** govern what a customer's API key can do on the Flapjack Cloud

management API. |
| startup.rs | Startup phase helpers — each function owns one logical phase of server

bootstrap, called in sequence by main(). |
| startup_env.rs | Stub summary for startup_env.rs. |
| startup_repos.rs | Repository initialization extracted from main startup. |
| state.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/state.rs. |
| usage.rs | Stub summary for usage.rs. |
| validation.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/validation.rs. |

| Directory | Summary |
| --- | --- |
| auth | The auth module provides authentication mechanisms including admin authentication, API key validation, and tenant isolation, with dedicated error handling and storage layers for managing authentication state and credentials. |
| dns | The dns directory provides DNS provider integrations for the API, with implementations for Cloudflare and AWS Route53. |
| invoicing | Defines utility functions for invoice line item generation and processing, including object storage egress billing with sub-cent carryforward between cycles and minimum spend threshold enforcement. |
| middleware | This middleware directory contains cross-cutting concerns for the HTTP API server, including request logging and metrics collection that instrument API traffic and performance. |
| models | The models directory defines database models and API conversion layers for core billing platform entities including customers, API keys, invoices, deployments, and rate cards. |
| provisioner | The provisioner module abstracts cloud infrastructure provisioning across multiple providers (AWS, GCP, OCI, Hetzner) with shared environment variable parsing utilities and provider-specific implementations. |
| repos | This directory contains the repository (data access) layer for the fjcloud API, providing trait definitions and concrete implementations for persisting and querying domain entities like customers, invoices, API keys, deployments, and storage resources. |
| router | Assembles the Axum HTTP router by organizing routes into functional groups (auth-limited, tenant-authenticated, admin, webhooks, internal, etc.) and applies rate limiting middleware to each. |
| routes | The routes directory contains the HTTP handler modules for fjcloud's axum API server, organizing endpoints across authentication, account management, billing, invoicing, index operations, storage, admin functions, and webhooks. |
| secrets | Secrets module providing abstraction layers for managing sensitive credentials and configuration data across multiple backends including AWS, in-memory storage, and mock implementations for testing. |
| services | The services directory contains domain-specific backend service modules for the fjcloud billing and infrastructure platform, including core infrastructure components (alerting, audit logging, email, metrics), data management systems (replication, migration, object storage, cold tier), API proxies (flapjack_proxy), scheduling and provisioning logic, and operational observability tools. |
| startup | The startup directory contains a stub StripeService implementation that returns NotConfigured for all operations when the Stripe secret key is not configured, allowing the API to bootstrap and serve non-Stripe functionality. |
| stripe | This directory contains the Stripe integration module for the billing engine, with separate implementations for production (live.rs) and local/test (local.rs) environments. |
<!-- [scrai:end] -->
