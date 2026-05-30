<!-- [scrai:start] -->
## api

| File | Summary |
| --- | --- |
| build.rs | Stub summary for build.rs. |

| Directory | Summary |
| --- | --- |
| src | The fjcloud API server implementation, organized into modules for HTTP routing, authentication, billing and invoicing, multi-cloud infrastructure provisioning, DNS management, data access, domain services, and Stripe payment integration. |
| tests | The tests directory contains shared test utilities and fixtures for the API integration test suite, including helper modules for capacity profiling, index routes, Flapjack proxy mocking, and Stripe webhook testing. |
| src | This is the main source directory for fjcloud's Axum-based HTTP API server, containing the complete backend implementation for billing, invoicing, customer management, OAuth authentication, cloud infrastructure provisioning, and webhook handling across multiple cloud providers. |
| tests | The tests/common directory provides shared test infrastructure for fjcloud API integration testing, including fixtures, mocks, and helpers for scheduler and placement testing, Flapjack proxy integration, Stripe webhooks, and S3 storage operations. |
<!-- [scrai:end] -->
