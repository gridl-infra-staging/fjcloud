<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | The aggregation-job is a daily rollup daemon that aggregates metering data into billing periods by executing parameterized SQL queries against PostgreSQL, with configuration loaded from environment variables and structured logging throughout. |
| api | — |
| billing | The billing crate implements the core billing engine that aggregates metering records into usage summaries and applies rate-card pricing to generate invoices. |
| metering-agent | Metering-agent is a Rust daemon that collects and reports resource consumption metrics for billing purposes, with integrated components for configuration, health monitoring, circuit breaking, and tenant mapping. |
| pricing-calculator | The pricing-calculator crate estimates search infrastructure costs across multiple providers (Algolia, AWS OpenSearch, Griddle, Meilisearch) using a provider registry, shared type definitions, presets, and RAM-based heuristics. |
<!-- [scrai:end] -->
