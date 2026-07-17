<!-- [scrai:start] -->
## api

| File | Summary |
| --- | --- |
| build.rs | Stub summary for build.rs. |

| Directory | Summary |
| --- | --- |
| src | The src directory is the main HTTP API server implementation for fjcloud, containing routing, middleware, request handlers, and database models organized by domain (auth, billing, provisioning, webhooks). |
| tests | The tests directory contains integration test infrastructure and test cases for the API server, with common/ providing shared test utilities and mock implementations, and integration/ containing comprehensive Rust integration tests covering Algolia import operations, catalog lifecycle management, and engine index identity verification. |
| src | This is the main Rust source directory for fjcloud's backend API server, implementing HTTP routing, authentication, billing infrastructure with Stripe integration, cloud provisioning across multiple providers, and data-access layers for customers and usage tracking. |
| tests | The tests directory contains integration tests and shared test infrastructure for fjcloud's core subsystems, including Algolia search workflows, catalog lifecycle management, and engine operations. |
<!-- [scrai:end] -->
