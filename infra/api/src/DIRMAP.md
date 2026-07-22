<!-- [scrai:start] -->
## src

| File | Summary |
| --- | --- |
| config.rs | Stub summary for infra/api/src/config.rs. |
| errors.rs | Stub summary for infra/api/src/errors.rs. |
| helpers.rs | Stub summary for helpers.rs. |
| invoicing.rs | Stub summary for invoicing.rs. |
| main.rs | Stub summary for infra/api/src/main.rs. |
| router.rs | Stub summary for infra/api/src/router.rs. |
| scopes.rs | Auth vocabulary for the Flapjack Cloud platform.



**Management scopes** govern what a customer's API key can do on the Flapjack Cloud

management API. |
| startup.rs | Startup phase helpers — each function owns one logical phase of server

bootstrap, called in sequence by main(). |
| startup_env.rs | Stub summary for startup_env.rs. |
| startup_repos.rs | Repository initialization extracted from main startup. |
| usage.rs | Stub summary for usage.rs. |

| Directory | Summary |
| --- | --- |
| auth | — |
| dns | — |
| invoicing | The invoicing module handles invoice generation and billing calculations, managing line items with fractional-cent carryforward logic for object storage egress, computing storage metrics from snapshots and buckets, and synchronizing invoice data to Stripe. |
| middleware | — |
| models | API data models including customers, API keys, rate cards, index metadata, and Algolia import operations with database persistence and validation. |
| provisioner | The provisioner module coordinates cloud infrastructure provisioning across multiple providers (AWS, Hetzner, OCI, GCP) with centralized environment configuration parsing and validation. |
| repos | This directory contains Rust repository implementations providing data access and persistence for a billing platform's core entities—customers, invoices, disputes, usage, tenants, VM infrastructure, and Algolia indexing jobs—all backed by PostgreSQL with specialized operations for billing cycles, lifecycle management, and event tracking. |
| router | — |
| routes | — |
| secrets | The secrets directory provides secret management abstractions for storing and rotating node API keys across different backends. |
| services | — |
| startup | This directory contains a stub StripeService that safely disables all Stripe operations when the secret key is unavailable, allowing the API to bootstrap for free-tier signups and admin features while cleanly returning NotConfigured for Stripe-gated handlers. |
| stripe | The stripe directory contains Stripe payment integration code with separate implementations for live and local environments. |
<!-- [scrai:end] -->
