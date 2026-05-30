<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | The aggregation-job binary aggregates metering data daily into PostgreSQL by executing a rollup query for a target date and reporting the number of affected rows. |
| api | The fjcloud API server implementation built with axum, providing HTTP routing, authentication, billing and invoicing, multi-cloud infrastructure provisioning, DNS management, and Stripe payment integration. |
| billing | The billing crate is the core billing calculation engine that aggregates raw metering records into usage summaries and applies rate card pricing to generate invoices. |
| metering-agent | The metering-agent is a Rust daemon that collects and reports resource usage metrics for billing purposes, with modules for configuration, data scraping, storage, and tenant mapping. |
| pricing-calculator | The pricing-calculator crate computes pricing across multiple search and storage providers (Algolia, AWS OpenSearch, Meilisearch, Flapjack Cloud) using a modular registry pattern with type definitions, preset configurations, and RAM-based heuristics. |
| aggregation-job | The aggregation-job crate is a scheduled task that initializes structured logging and database connectivity to aggregate metering data into daily rollups for billing cycles. |
| api | The api crate is fjcloud's Axum-based HTTP API server that handles billing, invoicing, customer management, OAuth authentication, cloud provisioning, and webhook processing for multiple cloud providers. |
| billing | The billing crate contains the invoice generation pipeline, aggregating raw metering records into usage summaries and applying configurable rate card pricing to produce customer invoices. |
| metering-agent | The metering-agent is a daemon that collects and reports resource consumption data for billing purposes, with modules handling configuration, metrics scraping, data storage, and tenant routing. |
| pricing-calculator | The pricing-calculator module provides core types, presets, and heuristics for calculating cloud service costs across multiple providers. |
<!-- [scrai:end] -->
