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
| startup.rs | Startup phase helpers extracted from main().



Each function owns one logical phase of server bootstrap. |
| startup_env.rs | Stub summary for startup_env.rs. |
| startup_repos.rs | Repository initialization extracted from main startup. |
| state.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/state.rs. |
| usage.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar22_pm_2_utoipa_openapi_docs/fjcloud_dev/infra/api/src/usage.rs. |
| validation.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/validation.rs. |

| Directory | Summary |
| --- | --- |
| auth | The auth module handles authentication and authorization for the fjcloud API, providing support for admin credentials, API key authentication, tenant-level access control, and credential storage while managing related errors. |
| dns | The dns directory contains modules for managing DNS operations through multiple providers: Cloudflare and AWS Route53. |
| invoicing | The invoicing directory contains billing logic, with line_items.rs handling the representation and management of individual line items within invoices. |
| middleware | The middleware directory contains HTTP middleware components for the axum API server, including request logging and metrics collection functionality. |
| models | The models directory contains Rust structs representing core domain entities like API keys, customers, deployments, invoices, and rate cards, along with their database schema definitions and conversion layers for API serialization. |
| provisioner | The provisioner module contains cloud infrastructure provisioning implementations for multiple cloud providers (AWS, GCP, OCI, Hetzner) with a shared environment-variable configuration system, plus supporting utilities for cloud-init setup, SSH configuration, region mapping, and testing. |
| repos | This directory contains the data access layer for the fjcloud backend, with trait definitions and multiple implementations (PostgreSQL and in-memory) for repository patterns across domain entities like customers, invoices, API keys, deployments, storage, and billing operations. |
| router | Route assembly helpers for organizing and configuring the public API, dashboard, and internal route subtrees. |
| routes | The `routes/` directory contains HTTP route handlers for the fjcloud API server, organized into modules for authentication, billing, user accounts, webhooks, and external integrations, with specialized subdirectories for administrative operations, search index management, and S3-compatible storage operations. |
| secrets | The secrets directory provides abstracted secret management for the API with multiple backend implementations: AWS-backed storage for production, in-memory storage for testing, and mock implementations for unit tests. |
| services | The services directory contains core API functionality modules including audit logging, email delivery, health monitoring, storage/replication, and resource provisioning, with specialized subdirectories for cold-tier archival, Flapjack proxy integration, data migration workflows, and job scheduling. |
| startup | This directory contains a stub Stripe service implementation that returns `NotConfigured` for all operations, extracted from `startup.rs` to maintain file size limits and used when the Stripe configuration is unavailable to allow the rest of the API to function normally. |
| stripe | The stripe module provides a trait-based abstraction (`StripeService`) for Stripe payment operations including customer management, payment methods, invoice creation, and webhook verification, with concrete implementations for live and local environments. |
<!-- [scrai:end] -->
