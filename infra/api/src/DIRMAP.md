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
| auth | The auth module handles multiple authentication mechanisms including admin access, API key validation, and tenant-based isolation, with supporting error types and storage persistence for authentication data. |
| dns | The dns directory provides DNS provider integrations for the fjcloud API, with implementations for Cloudflare and AWS Route53. |
| invoicing | The invoicing directory contains business logic for generating and managing invoice line items within the billing system. |
| middleware | The middleware directory contains HTTP request handling utilities for the Axum API server, including metrics collection and request logging middleware to instrument and observe API traffic. |
| models | The models directory contains core domain models for the fjcloud billing and infrastructure platform, including customer accounts, deployments, invoices, and rate cards with their corresponding database and API conversion layers. |
| provisioner | The provisioner module orchestrates infrastructure provisioning across multiple cloud providers (AWS, GCP, OCI, Hetzner) with shared environment-variable parsing, region mapping, and provisioning lifecycle management. |
| repos | This directory contains the data access layer (repository pattern) for fjcloud's billing platform, with trait definitions and PostgreSQL/in-memory implementations for domain entities including customers, invoices, API keys, deployments, storage resources, and billing-related data. |
| router | The router directory contains route assembly helpers that organize and structure HTTP routes across the public API, dashboard, and internal subtrees. |
| routes | The routes directory contains HTTP API endpoint handlers for the fjcloud platform, organized by feature area including authentication, billing, invoices, webhooks, storage/S3 operations, and index management. |
| secrets | The secrets directory provides a modular secrets management abstraction with implementations for AWS Secrets Manager, in-memory storage, and mock testing. |
| services | The services directory provides the core business logic and infrastructure integration layer for the API, including email delivery, audit logging, provisioning, replication, storage management, and scheduler components for resource allocation across the fjcloud platform. |
| startup | The startup directory contains a stub Stripe service implementation that allows the API to initialize without Stripe credentials by returning NotConfigured errors for all Stripe operations. |
| stripe | The stripe module provides Stripe integration for the billing system, with both live production and local in-memory implementations. |
<!-- [scrai:end] -->
