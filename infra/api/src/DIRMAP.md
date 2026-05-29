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
| auth | The auth module handles authentication and authorization for the fjcloud API, including admin authentication, API key management, tenant isolation, error handling, and persistent storage of authentication credentials and state. |
| dns | The dns directory provides DNS provider integrations for the API, supporting both Cloudflare and AWS Route53 as backend DNS services. |
| invoicing | The invoicing directory contains line_items.rs, which handles the generation and management of individual line items that compose invoices in the billing engine. |
| middleware | The middleware directory contains HTTP request handling middleware for the API server, including metrics collection and request logging functionality that instrument incoming requests. |
| models | The models directory contains database models and API conversion layers for core billing and infrastructure entities including customers, invoices, rate cards, API keys, and deployments. |
| provisioner | The provisioner directory contains multi-cloud infrastructure provisioning implementations for AWS, GCP, OCI, and Hetzner, with a shared env_config.rs module that provides consistent environment-variable parsing and validation across all provisioners. |
| repos | This directory contains repository abstractions and implementations for data access in the fjcloud API, including trait definitions and both PostgreSQL and in-memory implementations for entities like customers, invoices, deployments, storage buckets, API keys, and other domain objects. |
| router | The router directory contains route assembly logic for constructing and managing application routes. |
| routes | This routes directory contains HTTP endpoint handlers for the fjcloud API, implementing authentication, billing, account management, invoicing, webhooks, and admin operations, with specialized subdirectories for index management features and S3-compatible cloud storage operations. |
| secrets | The secrets directory provides multiple backend implementations for managing application secrets: AWS (credential provider), in-memory storage, and mock implementation for testing. |
| services | The services module contains the core business-logic layer for the fjcloud API, including infrastructure services for VM provisioning across multiple cloud providers, resource scheduling and load balancing, data migration orchestration, S3-compatible object storage, audit logging for admin actions, and proxying to underlying flapjack VMs. |
| startup | This directory contains a stub Stripe service implementation that returns `NotConfigured` for all operations, extracted from `startup.rs` to maintain file size constraints and used when Stripe credentials are unavailable, allowing the API to bootstrap and serve non-Stripe functionality. |
| stripe | The stripe module provides Stripe integration for the API, with separate implementations for live production mode and local testing mode. |
| auth | The auth module provides authentication and authorization mechanisms for the fjcloud API, including admin authentication, API key validation, tenant-based access control, and associated error handling and storage logic. |
| dns | The dns directory contains integrations with two DNS providers: Cloudflare and AWS Route 53. |
| invoicing | The invoicing directory contains line item handling code for the billing engine, managing the detailed line-by-line components of generated invoices. |
| middleware | The middleware directory contains HTTP request handling middleware for the API server, including modules for metrics collection and request logging. |
| models | The models directory contains core domain entities for the fjcloud API, including API keys, customers, deployments, invoices, and rate cards, with each module providing database model definitions and conversion layers between persistence and API representations. |
| provisioner | The provisioner directory implements multi-cloud infrastructure provisioning for AWS, GCP, OCI, and Hetzner, with env_config.rs serving as the canonical source for typed environment-variable parsing shared across all provisioner implementations. |
| repos | This directory contains the repository (data access) layer for the fjcloud platform, implementing the repository pattern for domain entities like customers, invoices, deployments, storage, and billing. |
| router | The router directory handles HTTP route assembly and configuration. |
| routes | This directory contains HTTP route handlers for the fjcloud API, organized by functional area including authentication, billing, user accounts, webhooks, and onboarding, with dedicated subdirectories for more complex domains like administrative operations, index management, and S3-compatible storage with metering integration. |
| secrets | The secrets directory provides abstraction for secret storage with multiple implementations: AWS Secrets Manager for production, in-memory storage for development, and mock implementations for testing. |
| services | The services directory is a collection of microservice modules providing core infrastructure functionality for the fjcloud API, including storage (S3-compatible object storage), data operations (cold tier, migration, replication), tenant management (provisioning, scheduling, quotas), and system integration (email, alerting, metrics, flapjack proxy). |
| startup | The startup directory contains a stub Stripe service implementation that returns NotConfigured for all operations when the Stripe secret key is not configured, allowing the API to bootstrap without Stripe while cleanly handling Stripe-dependent operations. |
| stripe | The stripe directory contains environment-specific Stripe integration implementations with separate live.rs and local.rs modules for production and development environments, coordinated through a central mod.rs module. |
<!-- [scrai:end] -->
