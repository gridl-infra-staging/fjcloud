<!-- [scrai:start] -->
## api

| File | Summary |
| --- | --- |
| build.rs | Stub summary for infra/api/build.rs. |

| Directory | Summary |
| --- | --- |
| src | The infra/api/src directory is the Rust backend server (Axum-based) for fjcloud's billing and infrastructure platform, providing HTTP endpoints for customer account management, billing, search indexes, storage operations, and administrative functions alongside supporting services for email delivery, webhooks, multi-cloud provisioning (AWS, GCP, OCI, Hetzner), and invoice generation. |
| tests | The tests directory provides integration tests and utilities for the API crate, validating critical workflows around VM inventory management, catalog leasing, and Algolia integration with comprehensive race-condition and invariant testing. |
<!-- [scrai:end] -->
