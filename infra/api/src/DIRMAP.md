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
| auth | The auth module provides multiple authentication and authorization mechanisms for the API, including admin authentication, API key management, tenant-based access control, and associated error handling and storage. |
| dns | The dns directory provides DNS management functionality with implementations for multiple DNS providers: Cloudflare and AWS Route53. |
| invoicing | The invoicing directory contains code for managing invoice line items. |
| middleware | The middleware directory contains HTTP middleware components for the API server, including metrics collection and request logging functionality. |
| models | Core domain models for the fjcloud billing system, defining database schemas and API conversion layers for customers, API keys, invoices, deployments, and rate cards. |
| provisioner | The provisioner module provides multi-cloud infrastructure provisioning support for AWS, GCP, OCI, and Hetzner, with shared environment configuration parsing and cloud initialization utilities. |
| repos | This directory contains the data access layer (repository pattern) for the fjcloud API crate, organizing database operations across PostgreSQL implementations, in-memory test doubles, and abstract trait definitions for domain entities like customers, invoices, API keys, storage, deployments, and billing data. |
| router | The router directory contains route assembly logic for the API server, managing the construction and registration of HTTP routes and handlers. |
| routes | The routes directory contains HTTP route handlers for the API server, covering customer-facing features like authentication, billing, invoicing, API keys, and OAuth, alongside admin operations for rate cards and infrastructure control, index management for search and analytics, and S3-compatible storage operations. |
| secrets | The secrets directory contains implementations for managing sensitive data across multiple backends: AWS (likely Secrets Manager or Parameter Store), in-memory storage, and mock implementations for testing purposes. |
| services | The services directory contains domain-specific service modules that implement core infrastructure and operational functions for the fjcloud platform, including email delivery, webhook handling, VM provisioning, storage management, resource scheduling, data migration, and external service proxying. |
| startup | The startup directory contains a stub StripeService implementation that gracefully disables Stripe operations when the configuration is missing, allowing the rest of the API to bootstrap and function with non-Stripe features intact. |
| stripe | This stripe module provides Stripe payment integration for fjcloud's billing system, with separate implementations for live production and local testing environments. |
| auth | The auth module provides authentication infrastructure for the API, including support for API key validation, admin access control, and tenant-based identity verification. |
| dns | The dns module contains provider implementations for managing DNS across Cloudflare and Route53, supporting the platform's infrastructure operations. |
| invoicing | The invoicing directory contains Rust code for handling invoice generation and line item management within the billing system. |
| middleware | The middleware directory contains HTTP request-handling middleware for the Axum API server, including request logging and metrics collection components. |
| models | The models directory contains data structures and database models for the fjcloud API, including entities for API keys, customers, deployments, invoices, and rate cards. |
| provisioner | The provisioner module provides cloud infrastructure provisioning implementations for multiple platforms (AWS, GCP, OCI, Hetzner) with a shared environment-configuration utility that standardizes how all provisioners read and validate typed environment variables. |
| repos | This directory contains the repository pattern implementations for fjcloud's data access layer, providing abstract traits and concrete PostgreSQL/in-memory implementations for domain entities including customers, invoices, deployments, storage, indexes, webhooks, and billing-related models. |
| router | The router directory contains route assembly logic for the API server, handling the construction and configuration of HTTP endpoints and their handlers. |
| routes | This directory implements the HTTP API route handlers for the fjcloud backend, covering core functionality including authentication, billing, invoices, webhooks, API key management, OAuth integration, and user onboarding. |
| secrets | The secrets module provides multiple implementations for managing sensitive credentials, including AWS Secrets Manager integration, in-memory storage, and a mock variant for testing. |
| services | The services module is a collection of supporting microservices for the fjcloud API that handle infrastructure provisioning, data replication and migration, storage proxying (S3), resource scheduling and quota management, email delivery, audit logging, and health monitoring. |
| startup | The `startup` directory contains a stub `StripeService` implementation that returns `NotConfigured` for all operations, extracted from `startup.rs` to maintain size limits. |
| stripe | The stripe directory contains Stripe integration code for the fjcloud billing system, with separate implementations for live production and local development environments. |
<!-- [scrai:end] -->
