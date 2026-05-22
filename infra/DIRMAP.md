<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | The aggregation-job crate is a periodic job that aggregates metering data collected by the metering-agent into billable usage summaries for billing cycles. |
| api | The api crate is the HTTP server backend for fjcloud, providing REST endpoints for customer-facing operations, multi-cloud provisioning, billing management, and third-party integrations including Stripe webhooks, DNS management, and email delivery. |
| billing | The billing directory contains the billing engine that aggregates raw metering records into usage summaries and applies rate card pricing to generate invoices. |
| metering-agent | The metering-agent is a daemon that collects and manages resource usage metrics for billing purposes, with components for metric scraping, data storage, tenant mapping, and health monitoring. |
| pricing-calculator | The pricing-calculator is a library that computes usage-based and resource-based pricing for fjcloud across multiple search and storage providers including Algolia, AWS OpenSearch, Griddle, and Meilisearch. |
<!-- [scrai:end] -->
