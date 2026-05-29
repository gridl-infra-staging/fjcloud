<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | The aggregation-job crate is a periodic service that processes collected usage metrics and aggregates them into billing-cycle data for the billing engine. |
| api | The `api` crate is fjcloud's core HTTP server implementing authentication, billing and invoicing, multi-cloud infrastructure provisioning (AWS/GCP/OCI/Hetzner), Stripe integration, webhook handlers, and resource management services. |
| billing | The billing engine aggregates raw metering records into usage summaries and applies rate card pricing to generate invoices, with shared types and configuration supporting multiple billing plans. |
| metering-agent | The metering-agent is a Rust daemon that collects and reports resource consumption metrics across tenants, with components for configuration management, health monitoring, circuit breaker resilience, metric scraping, and data storage. |
| pricing-calculator | The pricing-calculator module provides a registry-based infrastructure for computing resource costs across multiple search and storage service providers. |
| aggregation-job | The aggregation-job is a daily batch service that aggregates metering data by executing rollup queries against PostgreSQL for target date windows. |
| api | The api crate is an axum-based HTTP server that implements customer-facing endpoints for billing, provisioning across multiple cloud providers, Stripe integration, DNS management, and authentication. |
| billing | The billing directory implements fjcloud's core billing engine, executing a three-stage pipeline that aggregates metering records into billing-period summaries, applies rate-card pricing rules to generate invoices, and manages the supporting types and configurations that drive the calculations. |
| metering-agent | The metering-agent is a Rust daemon that collects resource usage metrics and stores consumption data for billing cycles while maintaining resilience through health monitoring and circuit-breaker patterns. |
| pricing-calculator | The pricing-calculator module implements cost estimation logic for multiple search and storage services including Algolia, AWS OpenSearch, Meilisearch, and Griddle, with shared types, RAM heuristics, and preset configurations. |
<!-- [scrai:end] -->
