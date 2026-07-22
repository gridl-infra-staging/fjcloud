<!-- [scrai:start] -->
## api

| File | Summary |
| --- | --- |
| build.rs | Stub summary for infra/api/build.rs. |

| Directory | Summary |
| --- | --- |
| src | The core HTTP API server for fjcloud's billing and infrastructure platform, built with Axum and implementing customer management, invoicing, multi-cloud provisioning (AWS/Hetzner), Stripe payment integration, authentication via JWT and API keys, search index management, webhooks, and operational services including audit logging and email delivery. |
| tests | The tests directory contains the fjcloud API's integration test suite, with common/ providing shared test utilities and fixtures and integration/ holding domain-specific tests for Algolia import, catalog lifecycle, and migration routes. |
<!-- [scrai:end] -->
