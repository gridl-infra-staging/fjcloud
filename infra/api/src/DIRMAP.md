<!-- [scrai:start] -->
## src

| File | Summary |
| --- | --- |
| config.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/config.rs. |
| errors.rs | Stub summary for errors.rs. |
| helpers.rs | Stub summary for helpers.rs. |
| invoicing.rs | Stub summary for invoicing.rs. |
| main.rs | Binary entrypoint for the Flapjack Cloud API service. |
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
| auth | The auth module handles multiple authentication mechanisms including admin access, API key validation, and tenant-based isolation, with supporting error types and storage persistence for authentication data. |
| dns | The dns directory provides DNS provider integrations for the fjcloud API, with implementations for Cloudflare and AWS Route53. |
| invoicing | The invoicing directory contains business logic for generating and managing invoice line items within the billing system. |
| middleware | The middleware directory contains HTTP request handling utilities for the Axum API server, including metrics collection and request logging middleware to instrument and observe API traffic. |
| models | The models directory contains core database schemas and API conversion layers for the billing system, including customer accounts, infrastructure deployments, invoices, subscriptions, and pricing rate cards. |
| provisioner | The provisioner module orchestrates infrastructure provisioning across multiple cloud providers (AWS, GCP, OCI, Hetzner) with shared environment-variable parsing, region mapping, and provisioning lifecycle management. |
| repos | The repos directory implements the repository pattern for data access across the fjcloud API, providing trait definitions and both PostgreSQL and in-memory concrete implementations for core domain entities (customers, invoices, api keys, deployments, storage buckets, etc.). |
| router | The router directory contains route assembly helpers that organize and structure HTTP routes across the public API, dashboard, and internal subtrees. |
| routes | The routes directory contains HTTP endpoint handlers for the fjcloud API, organized into feature-specific modules for account management, billing, authentication, usage tracking, webhooks, and public site endpoints, with three specialized subdirectories for admin operations, search index management, and S3-compatible storage operations. |
| secrets | The secrets directory provides a modular secrets management abstraction with implementations for AWS Secrets Manager, in-memory storage, and mock testing. |
| services | The services directory provides domain-specific implementations for fjcloud's multi-region infrastructure, including cluster scheduling, data replication and migration, infrastructure provisioning, S3-compatible storage via Garage, cold-tier archival, and flapjack VM orchestration. |
| startup | The startup directory contains a stub Stripe service implementation that allows the API to initialize without Stripe credentials by returning NotConfigured errors for all Stripe operations. |
| stripe | The stripe module provides Stripe integration for the billing system, with both live production and local in-memory implementations. |
<!-- [scrai:end] -->
