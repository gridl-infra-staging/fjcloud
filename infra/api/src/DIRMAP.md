<!-- [scrai:start] -->
## src

| File | Summary |
| --- | --- |
| config.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/config.rs. |
| errors.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/errors.rs. |
| helpers.rs | Stub summary for helpers.rs. |
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
| dns | The dns directory contains provider implementations for DNS service integrations, specifically adapters for Cloudflare and AWS Route53 DNS services. |
| invoicing | The invoicing module handles invoice generation and Stripe synchronization, computing billable line items for storage services (cold storage, object storage egress) with fractional cent carryforward tracking and syncing invoices to Stripe with persisted metadata. |
| middleware | The middleware directory provides request instrumentation through metrics collection and structured request/response logging with JWT tenant extraction, supporting path template normalization, request duration tracking, and status-based logging levels. |
| models | The models directory contains core domain entities for the billing and cloud infrastructure platform, including customers, subscriptions, invoices, rate cards, deployments, and tenant configurations. |
| provisioner | The provisioner directory contains a multi-cloud VM provisioning abstraction that supports AWS, GCP, OCI, and Hetzner through provider-specific modules, sharing common utilities for environment configuration, SSH access, and cloud-init management. |
| repos | This directory contains repository implementations for data access across the fjcloud system, organized as trait definitions (abstract repos) with concrete implementations for PostgreSQL persistence and in-memory backends for testing. |
| router | I need the full file path or contents of `route_assembly.rs` to provide an accurate summary. |
| routes | The routes directory contains HTTP API endpoint handlers for the fjcloud platform, organized by feature domains including authentication, billing, invoicing, account management, indexes/search, admin operations, storage/S3, and integration services like AllYourBase. |
| secrets | The secrets directory provides multiple implementations of a NodeSecretManager interface for managing per-node Flapjack API keys: an AWS SSM Parameter Store backend for production, an in-memory backend for local development, and a test mock with injectable failures for testing. |
| services | The services directory contains modular infrastructure and operational services that handle provisioning, replication, scheduling, tiering, monitoring, and cloud integration for the fjcloud API. |
| stripe | The stripe module provides a pluggable Stripe integration abstraction with two implementations: a live service wrapping the official Stripe SDK for production payment operations, and a local mock service for zero-dependency local development that dispatches signed webhook events to the API endpoint. |
<!-- [scrai:end] -->
