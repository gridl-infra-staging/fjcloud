<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | The aggregation-job is a daily batch process that performs metering data rollups into billing periods by connecting to PostgreSQL and executing rollup queries for specified date windows. |
| api | The api crate is fjcloud's HTTP API server built in Rust with axum, providing multi-tenant authentication, billing and invoice management, multi-cloud provisioning orchestration (AWS/GCP/OCI/Hetzner), Stripe integration, and operational services like email and webhooks. |
| billing | The billing crate is a Rust module that aggregates raw metering records into billing-period summaries and applies rate-card pricing logic to generate customer invoices. |
| metering-agent | The metering-agent crate collects and reports resource consumption metrics across tenants, providing configuration, health monitoring, data scraping, recording, and storage with circuit breaker resilience. |
| pricing-calculator | The pricing-calculator crate is a pricing calculation engine that supports multiple search provider backends including Algolia, AWS OpenSearch, Meilisearch, and Griddle. |
<!-- [scrai:end] -->
