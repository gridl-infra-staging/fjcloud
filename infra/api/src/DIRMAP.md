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
| auth | This module provides authentication and authorization logic for the fjcloud API, including support for API key authentication, admin access control, multi-tenant authorization, error handling, and data storage. |
| dns | The dns directory contains integrations for DNS providers, with modules for Cloudflare and AWS Route53 DNS management. |
| invoicing | The invoicing directory contains code for handling invoice line item management. |
| middleware | The middleware directory contains HTTP request handling middleware for the Axum API server, including metrics collection and request logging. |
| models | This directory defines the core data models for the fjcloud API including customers, deployments, invoices, API keys, and rate cards. |
| provisioner | The provisioner module provides multi-cloud VM provisioning support for AWS, GCP, OCI, and Hetzner, with a shared environment-variable parsing layer that centralizes typed configuration reading, trimming, and validation across all provisioners. |
| repos | This directory contains the data access layer for the fjcloud API, implementing repository traits and their PostgreSQL-backed implementations for domain entities including customers, invoices, deployments, storage, API keys, and billing-related data, with in-memory implementations available for testing. |
| router | The router directory contains route assembly logic for organizing and composing API or application routes. |
| routes | This directory contains the HTTP route handlers for the fjcloud API server, organized as individual endpoint files for core features like authentication, billing, invoices, and webhooks, plus subdirectories for larger feature areas including administrative operations, index management, and S3-compatible storage endpoints. |
| secrets | The secrets module provides pluggable backend implementations for managing secrets, with support for AWS-based storage, in-memory caching, and test mocks. |
| services | The services directory contains modular implementations of cross-cutting infrastructure concerns for the fjcloud API, including email delivery, data replication and migration, S3-compatible storage, monitoring and health checks, webhook handling, provisioning, and scheduling. |
| startup | The startup directory contains a stub Stripe service implementation that allows the API to bootstrap without a configured Stripe secret key, returning NotConfigured for all operations while enabling free-tier signups and admin functionality. |
| stripe | The stripe directory contains the Stripe integration module for the fjcloud API, with separate implementations for local development (local.rs) and production environments (live.rs). |
<!-- [scrai:end] -->
