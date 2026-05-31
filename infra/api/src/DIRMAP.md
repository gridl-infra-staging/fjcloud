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
| auth | The auth directory implements authentication and authorization for the API, including admin access control, API key validation, tenant isolation, storage of auth-related data, and error handling for authentication failures. |
| dns | The dns directory contains DNS provider integrations for Cloudflare and Route53, implementing domain management operations across multiple DNS backends. |
| invoicing | The invoicing directory contains modules for invoice generation and line item management. |
| middleware | The middleware directory contains HTTP request handling utilities for the API layer, including request logging and metrics collection. |
| models | The models directory contains domain models for the billing and customer management system, including API keys, customers, deployments, invoices, and rate cards. |
| provisioner | The provisioner directory contains multi-cloud infrastructure provisioning modules supporting AWS, GCP, OCI, and Hetzner, with shared environment-variable parsing logic in env_config.rs that ensures consistent configuration handling across all provisioners. |
| repos | This directory contains the repository/data access layer for fjcloud, implementing the repository pattern with trait definitions and multiple backend implementations (PostgreSQL and in-memory) for domain entities like customers, invoices, deployments, storage buckets, indexes, and webhooks. |
| router | The router directory contains route_assembly.rs, which currently has only a stub documentation placeholder and lacks substantive documentation of its purpose and functionality. |
| routes | The routes directory contains HTTP endpoint handlers for the fjcloud API, organized by feature domain (auth, billing, invoices, webhooks, storage, indexes, and admin operations). |
| secrets | The secrets directory contains the secrets management abstraction for the API, with implementations for AWS Secrets Manager (aws.rs), in-memory storage (memory.rs), and testing mocks (mock.rs). |
| services | The services directory contains the API server's domain-specific functionality modules, including billing operations, customer provisioning, email handling, data replication and migration, alerting, and integrations with external systems like flapjack proxy. |
| startup | The `startup` directory contains a stub Stripe service implementation that returns `NotConfigured` for all operations when the Stripe secret key is not configured, allowing the API to bootstrap and handle non-Stripe features while gracefully rejecting Stripe-dependent operations. |
| stripe | The stripe module provides Stripe integration for the fjcloud billing API, with separate implementations for live production Stripe and local test modes. |
<!-- [scrai:end] -->
