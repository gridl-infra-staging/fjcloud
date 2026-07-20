<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | — |
| api | The api directory implements the fjcloud HTTP API server using axum, providing core modules for HTTP routing, authentication, database persistence, billing and invoicing, cloud provider provisioning, and Stripe payment processing. |
| billing | The billing module is a Rust crate that aggregates raw metering records into usage summaries and applies rate-card pricing to generate invoices. |
| metering-agent | The metering-agent is a Rust daemon that collects and reports resource consumption metrics across multiple tenants, with built-in configuration management and counter/metric tracking for usage billing. |
| pricing-calculator | The pricing-calculator crate implements modular pricing calculations for various cloud services through a central registry of pluggable providers, including support for Flapjack Cloud storage pricing. |
| retention-job | A scheduled batch job that automatically hard-erases deleted customer data from the database after a configurable retention period. |
<!-- [scrai:end] -->
