<!-- [scrai:start] -->
## src

| File | Summary |
| --- | --- |
| config.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/config.rs. |
| errors.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/errors.rs. |
| helpers.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/helpers.rs. |
| invoicing.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar21_pricing_model_hardening/fjcloud_dev/infra/api/src/invoicing.rs. |
| main.rs | Stub summary for main.rs. |
| router.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/router.rs. |
| scopes.rs | Auth vocabulary for the Griddle platform.



**Management scopes** govern what a customer's API key can do on the Griddle

management API. |
| startup.rs | Startup phase helpers extracted from main().



Each function owns one logical phase of server bootstrap. |
| startup_env.rs | Stub summary for startup_env.rs. |
| startup_repos.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar26_am_1_local_stack_zero_deps/fjcloud_dev/infra/api/src/startup_repos.rs. |
| state.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/state.rs. |
| usage.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/usage.rs. |
| validation.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/validation.rs. |

| Directory | Summary |
| --- | --- |
| auth | The auth directory contains authentication and authorization logic for the API, including admin access control, API key validation, tenant isolation, error handling, and a storage layer for auth data. |
| dns | The dns directory contains Route53 integration for managing DNS A records through AWS Route53, with methods to create, upsert, and delete hostname-to-IP mappings with proper FQDN formatting and idempotent delete handling. |
| invoicing | The invoicing module handles invoice generation and Stripe synchronization, computing billable line items for storage services (cold storage, object storage egress) with fractional cent carryforward tracking and syncing invoices to Stripe with persisted metadata. |
| middleware | The middleware directory provides request instrumentation through metrics collection and structured request/response logging with JWT tenant extraction, supporting path template normalization, request duration tracking, and status-based logging levels. |
| models | The models directory contains domain data type definitions for the API, including Customer, BillingPlan, Invoice, Deployment, Subscription, RateCard, and AybTenant types. |
| provisioner | The provisioner module provides a multi-cloud abstraction for virtual machine provisioning and lifecycle management across AWS, GCP, OCI, and Hetzner, with centralized environment configuration parsing and mock implementations for testing. |
| repos | The repos directory contains the data access layer for the fjcloud API, implementing the repository pattern with both PostgreSQL and in-memory backends for domain entities including customers, tenants, invoices, deployments, storage, and billing artifacts. |
| router | This module assembles and organizes all HTTP routes for the Axum API server, composing them into logical groups for authentication, billing, account management, index operations, analytics, experiments, and admin functions with optional rate limiting. |
| routes | The routes directory contains HTTP API endpoint handlers for the fjcloud platform, organized into core modules for authentication, billing, usage, invoices, and onboarding, plus subdirectories for administrative operations, AllYourBase tenant management, Flapjack search engine operations, and S3-compatible object storage. |
| secrets | The secrets directory provides pluggable secret storage backends for the API, including AWS Secrets Manager integration, in-memory storage, and a mock implementation for testing. |
| services | The services directory contains modular infrastructure and operational services that handle provisioning, replication, scheduling, tiering, monitoring, and cloud integration for the fjcloud API. |
| stripe | The stripe module provides a pluggable Stripe integration abstraction with two implementations: a live service wrapping the official Stripe SDK for production payment operations, and a local mock service for zero-dependency local development that dispatches signed webhook events to the API endpoint. |
<!-- [scrai:end] -->
