<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | The aggregation-job is a daily rollup daemon that aggregates metering data into billing periods by executing parameterized SQL queries against PostgreSQL, with configuration loaded from environment variables and structured logging throughout. |
| api | The fjcloud API is a Rust-based HTTP backend that manages billing, multi-region infrastructure provisioning, authentication, and cloud resource orchestration with integrations for Stripe payments, AWS/GCP/OCI provisioning, DNS, and PostgreSQL. |
| billing | The billing crate implements the invoice generation pipeline, transforming raw metering records into billing-period summaries and applying rate-card pricing logic to calculate invoices. |
| metering-agent | Metering-agent is a Rust daemon that collects and reports resource consumption metrics for billing purposes, with integrated components for configuration, health monitoring, circuit breaking, and tenant mapping. |
| pricing-calculator | The pricing-calculator crate estimates search infrastructure costs across multiple providers (Algolia, AWS OpenSearch, Griddle, Meilisearch) using a provider registry, shared type definitions, presets, and RAM-based heuristics. |
<!-- [scrai:end] -->
