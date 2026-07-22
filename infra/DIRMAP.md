<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | — |
| api | The API is an Axum-based HTTP server that implements core backend services for fjcloud's billing and infrastructure platform, including customer management, invoicing, multi-cloud provisioning, Stripe integration, JWT/API key authentication, search indexing, webhooks, audit logging, and email delivery. |
| billing | The billing crate implements the core billing engine, aggregating raw metering records into billing-period summaries and applying configurable rate-card pricing to generate invoices. |
| metering-agent | The metering-agent is a daemon that collects host resource metrics and usage counters from infrastructure, organizing and storing them by tenant for billing purposes. |
| pricing-calculator | The pricing-calculator directory contains modular implementations of pricing providers for various cloud services, coordinated through a registry system. |
| retention-job | The retention-job is a periodic task that identifies deleted customer accounts exceeding a configurable retention period (default 30 days) and purges their data via hard-erase API calls, with support for dry-run mode and per-run execution limits. |
<!-- [scrai:end] -->
