<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | The aggregation-job is a daily rollup daemon that consolidates metered usage data into billing periods by querying PostgreSQL and reporting affected row counts. |
| api | The infra/api directory contains fjcloud's main HTTP API server, a Rust-based Axum service that orchestrates billing, metering, and infrastructure provisioning across multiple cloud providers. |
| billing | The billing crate is the core engine that transforms raw metering data into invoices by aggregating usage records, applying rate-card pricing logic, and integrating with Stripe. |
| metering-agent | The metering-agent is a Rust daemon that collects and reports resource consumption metrics across tenants for the fjcloud billing system. |
| pricing-calculator | The pricing-calculator crate computes pricing for multiple search and storage services (Algolia, AWS OpenSearch, Meilisearch, Griddle) by implementing usage-based, resource-based, and flat-rate pricing models. |
<!-- [scrai:end] -->
