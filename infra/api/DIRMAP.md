<!-- [scrai:start] -->
## api

| File | Summary |
| --- | --- |
| build.rs | Stub summary for build.rs. |

| Directory | Summary |
| --- | --- |
| src | The fjcloud API's `src/` directory contains the core HTTP server (Axum-based) for a cloud billing platform, organized across modules for authentication, routing, business logic (invoicing, provisioning), data access (PostgreSQL repositories), cloud provider integrations (AWS, GCP, OCI, Hetzner, Stripe, Cloudflare), and operational utilities like middleware and secrets management. |
| tests | This directory contains API integration test utilities and fixtures, including property-based tests for tenant isolation and shared builders, mocks, and helpers for Stripe webhooks, Flapjack proxy operations, storage metering, and S3 routing. |
<!-- [scrai:end] -->
