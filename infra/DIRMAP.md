<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | The aggregation-job is an async Rust CLI that connects to PostgreSQL and executes daily rollup queries to aggregate metering data for billing cycles, reporting affected rows. |
| api | The api directory implements the fjcloud HTTP API server in Rust using axum, providing route handlers for billing, authentication, indexing, cloud operations, and integration with Stripe, DNS management, and multi-cloud VM provisioning. |
| billing | The billing crate implements fjcloud's invoice generation and pricing logic, managing rate cards, billing plans, and pricing calculations. |
| metering-agent | The metering-agent is a usage metering daemon that collects resource consumption metrics across multi-tenant deployments and stores the data for billing cycles. |
| pricing-calculator | — |
<!-- [scrai:end] -->
