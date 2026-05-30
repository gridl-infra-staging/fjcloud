<!-- [scrai:start] -->
## routes

| File | Summary |
| --- | --- |
| legal_page_test_helpers.ts | Stub summary for legal_page_test_helpers.ts. |

| Directory | Summary |
| --- | --- |
| admin | The admin directory contains the SvelteKit frontend routes and components for the admin dashboard, including pages for managing alerts, billing, customers, and index migrations with their associated server-side handlers and test fixtures. |
| api | The api directory contains SvelteKit server routes for handling pricing comparisons and Stripe integration, including endpoints for serving Stripe publishable keys and managing price comparison functionality. |
| auth | The auth directory contains OAuth authentication logic, with provider-specific callback handlers in the oauth/ subdirectory that implement server-side SvelteKit routes to process authorization responses from external providers like Google and GitHub. |
| billing | The billing directory contains SvelteKit server endpoints for handling billing-related operations, including an upgrade endpoint that manages upgrade transactions and related functionality. |
| console | The console directory is a SvelteKit-based customer dashboard that provides routes for account management, API key administration, billing workflows, index and document management, user onboarding, and email verification. |
| admin | The admin directory implements the SvelteKit admin dashboard with pages for managing alerts, billing operations, customer data, and database migrations. |
| api | The api directory contains SvelteKit server-side endpoints for customer-facing functionality including pricing comparisons, authenticated index searches, and Stripe integration for handling payments and publishable credentials. |
| auth | The auth directory handles OAuth authentication for the application, with provider-specific subdirectories containing SvelteKit server route handlers that process OAuth callbacks from external providers like Google and GitHub. |
| billing | The billing crate is a Rust library implementing the core billing engine with modules for invoice generation, pricing logic, rate cards, metering aggregation, and type definitions used across the fjcloud platform's billing system. |
| console | The console directory contains SvelteKit server-side route handlers for a customer-facing dashboard, providing functionality for account management, API key administration, billing operations, index management with various features, onboarding flows, and email verification. |
| dashboard | — |
| dev_editor_dialog_demo | — |
| forgot-password | — |
| login | — |
| logout | — |
| pricing | — |
| reset-password | — |
| signup | — |
| status | Defines type contracts and utilities for the /status route, including ServiceStatus enum (operational/degraded/outage), status data structures, and functions to parse status strings and map them to human-readable labels. |
| status | The status directory contains a TypeScript contract file that defines status-related type definitions and validation schemas. |
| verify-email | — |
<!-- [scrai:end] -->
