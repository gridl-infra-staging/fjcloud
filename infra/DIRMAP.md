<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | — |
| api | The api crate is an Axum-based HTTP server providing core backend services for fjcloud's billing and infrastructure platform, exposing endpoints for account management, billing, search indexes, storage operations, and multi-cloud VM provisioning across AWS, GCP, OCI, and Hetzner alongside supporting services for webhooks, email delivery, and invoicing. |
| billing | The billing crate implements the core billing engine, aggregating usage metering data into billing-period summaries and applying rate card pricing rules to calculate invoices. |
| metering-agent | The metering-agent is a daemon that collects and reports resource consumption through host metrics collection, counter tracking, and storage management across multiple tenants. |
| pricing-calculator | The pricing-calculator implements a modular pricing system with a registry-based architecture for managing provider implementations, including support for Griddle's flat per-MB storage pricing model and Algolia integration. |
| retention-job | The retention-job crate is a batch cleanup service that hard-deletes customer records older than a configured retention period by querying deleted customers from the database and invoking HTTP API endpoints. |
<!-- [scrai:end] -->
