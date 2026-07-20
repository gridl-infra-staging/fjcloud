<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | — |
| api | The infra/api directory is an Axum-based HTTP API backend serving the fjcloud platform with REST endpoints for customer management, billing, Algolia search integration, cloud provisioning across multiple providers (AWS, Hetzner, OCI, GCP), and Stripe payments. |
| billing | The billing engine aggregates usage metering data into billing-period summaries and applies configurable rate-card pricing to generate invoices. |
| metering-agent | The metering-agent is a usage metering daemon that collects and reports resource consumption for the billing platform, with a core architecture built around configuration management, counters, tenant mapping, and storage abstraction. |
| pricing-calculator | The pricing-calculator directory contains provider implementations for calculating cloud platform costs, with griddle.rs implementing Flapjack Cloud's flat per-MB hot storage pricing model and mod.rs serving as a registry for all available pricing providers. |
| retention-job | The retention-job crate manages data lifecycle and cleanup operations for the fjcloud platform, executing periodic retention tasks to remove or archive expired data. |
<!-- [scrai:end] -->
