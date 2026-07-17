<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | — |
| api | The api directory contains the HTTP API server implementation for fjcloud, with routing, middleware, and request handlers organized by domain alongside database models. |
| billing | The billing crate implements the core invoicing engine that transforms raw usage metering records into billable summaries using rate card pricing calculations. |
| metering-agent | The metering-agent is a Rust daemon that collects and reports resource usage data for the billing system, with core components handling multi-tenant configuration, counter logic, storage abstraction, and tenant mapping. |
| pricing-calculator | The pricing-calculator is a Rust module that computes pricing for various cloud services like Algolia and Flapjack Cloud storage through a central registry of pricing providers. |
| retention-job | The retention-job is a scheduled background task that permanently deletes customer records that have been marked for deletion after they exceed a configurable retention period. |
| api | The api directory contains fjcloud's backend HTTP server implementation in Rust, featuring axum-based routing, Stripe billing integration, multi-provider cloud provisioning, customer authentication, and metering data access layers. |
| billing | The billing crate implements the core billing engine that aggregates raw usage metering records into billing-period summaries and calculates invoices by applying rate-card pricing. |
| metering-agent | The metering-agent is a multi-tenant Rust daemon that collects and reports resource usage across tenants, with configurable storage, usage counters, and tenant routing logic. |
| pricing-calculator | The pricing-calculator crate provides a registry and implementations for pricing providers used by the billing system, including configurable storage pricing models with free tier and minimum spend options for services like Flapjack Cloud. |
| retention-job | The retention-job crate is a periodic cleanup daemon that hard-erases customers from the system after a configurable retention period, supporting dry-run mode and per-run limits. |
<!-- [scrai:end] -->
