<!-- [scrai:start] -->
## api

| File | Summary |
| --- | --- |
| build.rs | Stub summary for build.rs. |

| Directory | Summary |
| --- | --- |
| src | The `infra/api/src/` directory is the core HTTP API server implementation for fjcloud, containing authentication and authorization, billing and invoicing logic, multi-cloud infrastructure provisioning across AWS/GCP/OCI/Hetzner, Stripe integration, data repositories, webhook handlers, and business-logic services for resource management and metering. |
| tests | The tests directory provides shared test infrastructure and fixtures for API integration testing, including test state builders, Flapjack proxy stubs, Stripe webhook utilities, and S3 storage test harnesses. |
| src | This is the main API server source code for fjcloud, implementing HTTP endpoints and business logic for customer management, billing, infrastructure provisioning across multiple cloud providers (AWS, GCP, OCI, Hetzner), Stripe integration, DNS management, and authentication/authorization. |
| tests | This directory provides shared test fixtures, helpers, and mocks for the API integration test suite, including utilities for capacity profiling, Flapjack proxy simulation, Stripe webhook handling, and storage/metering validation. |
<!-- [scrai:end] -->
