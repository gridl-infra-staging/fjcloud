<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | The aggregation-job crate periodically aggregates metering data collected by the metering-agent into billing cycles for invoice generation. |
| api | The api directory contains the fjcloud HTTP API server implementation built with axum, providing route handlers for authentication, billing, invoicing, multi-cloud provisioning, and integrations with Stripe, DNS, and email services. |
| billing | The billing module aggregates metering records into billing-period summaries and applies rate-card pricing logic to calculate customer invoices. |
| metering-agent | The metering-agent is a daemon that collects usage metrics from infrastructure resources, storing records and managing tenant associations with built-in health monitoring and circuit breaker resilience patterns. |
| pricing-calculator | The pricing-calculator crate provides pricing models and calculations for multiple search and database services including Algolia, AWS OpenSearch, Griddle, and Meilisearch. |
<!-- [scrai:end] -->
