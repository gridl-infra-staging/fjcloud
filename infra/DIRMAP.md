<!-- [scrai:start] -->
## infra

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| aggregation-job | The aggregation-job is an async Rust CLI that connects to PostgreSQL and executes daily rollup queries to aggregate metering data for billing cycles, reporting affected rows. |
| api | The api directory contains the fjcloud HTTP API server implementation in src/, organized into modular layers handling routing, authentication, billing, data access, and infrastructure services like provisioning, Stripe integration, DNS, and secrets. |
| billing | The billing crate implements fjcloud's invoice generation and pricing logic, managing rate cards, billing plans, and pricing calculations. |
| metering-agent | The metering-agent is a daemon that collects resource consumption metrics from various sources through scrapers and persists them with circuit breaker protection and tenant isolation. |
| pricing-calculator | — |
<!-- [scrai:end] -->
