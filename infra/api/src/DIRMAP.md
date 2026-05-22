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
| auth | The auth module provides authentication and authorization mechanisms for the API, supporting multiple schemes including admin authentication, API key validation, and tenant-based access control, with dedicated error handling and storage layers. |
| dns | This dns module provides DNS provider integrations for managing DNS records across Cloudflare and AWS Route53, supporting multi-provider DNS operations for the infrastructure. |
| invoicing | The invoicing directory contains line_items.rs, which handles line item functionality for invoice generation and billing operations. |
| middleware | The middleware directory contains HTTP middleware components for the API server, including request logging and metrics collection functionality for monitoring and observability. |
| models | The models directory contains database model definitions and API conversion layers for the core fjcloud entities: customer, deployment, invoice, and rate card. |
| provisioner | The provisioner module is a multi-cloud infrastructure provisioning abstraction layer that supports OCI, GCP, Hetzner, AWS, and mock providers, with centralized environment-variable configuration parsing to ensure consistent typed value handling across all provisioner implementations. |
| repos | This directory contains the data access layer for the fjcloud API, implementing the repository pattern with abstract trait definitions and concrete implementations for PostgreSQL and in-memory backends across various domain entities like customers, invoices, storage buckets, API keys, and billing-related data. |
| router | The router directory contains route assembly utilities for organizing HTTP endpoints across the application's three main API subtrees: the public API, customer dashboard, and internal services. |
| routes | The routes module contains HTTP endpoint handlers for the fjcloud billing platform's API server, covering authentication, billing operations, invoices, webhooks, and administrative tasks alongside index operations and S3-compatible storage integration. |
| secrets | The secrets directory provides abstractions for credential management with multiple backend implementations: AWS Secrets Manager integration, in-memory storage, and mock implementations for testing. |
| services | The services module provides core business logic and infrastructure functionality for the fjcloud API, including email delivery, audit logging, webhooks, metrics, provisioning across cloud providers, S3-compatible storage proxying, and various operational services like health monitoring and replication management. |
| startup | The startup directory contains a stub Stripe service implementation that gracefully handles cases where Stripe is not configured, allowing the API to bootstrap and serve non-Stripe operations while returning a clean NotConfigured error for Stripe-dependent features. |
| stripe | The stripe module provides an abstraction for Stripe payment operations through a StripeService trait, defining core types and errors for invoice management, payment methods, subscriptions, and webhook handling. |
<!-- [scrai:end] -->
