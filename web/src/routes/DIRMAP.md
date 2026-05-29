<!-- [scrai:start] -->
## routes

| File | Summary |
| --- | --- |
| legal_page_test_helpers.ts | Stub summary for legal_page_test_helpers.ts. |

| Directory | Summary |
| --- | --- |
| admin | The admin directory provides the server-side backend for an administrative console with functional sections for billing management (invoice enrichment and batch operations), customer administration (including individual customer detail pages), and stub implementations for alerts and migrations. |
| api | The `api` directory contains SvelteKit server endpoints for the web frontend's external-facing functionality, including pricing comparison and Stripe publishable key management. |
| billing | The upgrade/ directory contains a SvelteKit server route handler that manages upgrade-related operations for the billing system, though the core implementation logic is currently stubbed out pending development. |
| console | The console directory is the SvelteKit customer-facing dashboard containing server-side route handlers for account management, API keys, billing configuration, index management, onboarding, and email verification. |
| admin | The admin directory contains SvelteKit server routes for administrative operations, including alert management with severity filtering, batch billing and invoice finalization tools, customer management pages, and database migration controls. |
| api | The api directory contains SvelteKit server routes for core customer-facing features including pricing comparison, authenticated index search, and Stripe integration. |
| billing | The billing directory contains upgrade-related functionality, specifically a SvelteKit server route handler that manages upgrade operations. |
| console | The console directory contains the customer-facing SvelteKit dashboard for managing fjcloud accounts, including pages for account settings, API key management, billing and payment setup, index management with multiple features, Algolia migration, onboarding flow, and email verification resend functionality. |
| dashboard | — |
| dev_editor_dialog_demo | — |
| forgot-password | — |
| login | — |
| logout | — |
| oauth | The oauth directory implements OAuth authentication handlers for social login integration, specifically with the callback subdirectory managing provider (Google, GitHub) authorization responses and session establishment. |
| pricing | — |
| reset-password | — |
| signup | — |
| status | Defines the TypeScript contract for the `/status` route, including the `ServiceStatus` type enum (operational/degraded/outage) and parsing utilities for converting raw status values to typed service status with human-readable labels. |
| oauth | The oauth directory handles OAuth authentication flows, specifically processing callbacks from social login providers like Google and GitHub. |
| pricing | — |
| reset-password | — |
| signup | — |
| status | This directory contains status contract definitions, likely for type-safe validation or testing of status-related API responses or data structures in the web frontend. |
| verify-email | — |
<!-- [scrai:end] -->
