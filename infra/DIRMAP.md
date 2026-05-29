<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | The aggregation-job is a daily rollup service that consolidates metering data into billing periods by executing PostgreSQL queries over target date windows. |
| api | The api directory contains fjcloud's Rust-based HTTP API server (axum), providing endpoints for authentication, billing and invoicing, multi-cloud provisioning, Stripe webhook handling, and operational alerting/metrics services. |
| billing | The billing crate aggregates metering records into usage summaries, applies rate cards to calculate pricing, and generates invoices as the core billing engine. |
| metering-agent | The metering-agent crate collects and reports resource consumption metrics for billing purposes, with built-in configuration, health monitoring, circuit-breaking, and multi-tenant data management. |
| pricing-calculator | The pricing-calculator crate computes pricing for multiple cloud services including Algolia, AWS OpenSearch, Griddle/Flapjack Cloud, and Meilisearch, using provider-specific implementations coordinated through a module registry. |
<!-- [scrai:end] -->
