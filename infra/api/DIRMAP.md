<!-- [scrai:start] -->
## api

| File | Summary |
| --- | --- |
| build.rs | Stub summary for infra/api/build.rs. |

| Directory | Summary |
| --- | --- |
| src | The infra/api/src directory is the Axum-based HTTP API backend for the fjcloud platform, implementing REST endpoints for customer management, billing, Algolia search integration, cloud provisioning (AWS, Hetzner, OCI, GCP), Stripe payments, and administrative operations. |
| tests | The tests directory provides integration test coverage for the fjcloud API with shared utilities, mocks, and fixtures, validating critical workflows including Algolia imports, catalog lease management, and migration routes with particular focus on race conditions and concurrent operation scenarios. |
<!-- [scrai:end] -->
