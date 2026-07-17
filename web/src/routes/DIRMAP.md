<!-- [scrai:start] -->
## routes

| File | Summary |
| --- | --- |
| legal_page_test_helpers.ts | Stub summary for legal_page_test_helpers.ts. |

| Directory | Summary |
| --- | --- |
| admin | The admin directory contains server-side SvelteKit routes for the administrative dashboard, including modules for alerts filtering, billing, customer management, and migrations handling that integrate with an admin client API. |
| api | The `api` directory contains SvelteKit server-side route handlers for frontend features like pricing comparison and search event tracking, each validating inputs and delegating to backend APIs with fallback logic for local development. |
| auth | — |
| billing | The billing directory contains an upgrade subdirectory with a SvelteKit server route handler for managing upgrade requests, currently implemented as a stub. |
| console | The console directory is a SvelteKit server-side dashboard application that provides user-facing functionality for managing accounts, API keys, search indexes, billing, and onboarding workflows. |
| admin | The admin directory contains SvelteKit-based administrative dashboard pages for managing billing, customers, alerts, and database migrations across the platform. |
| api | The api directory contains SvelteKit server routes that support the customer-facing dashboard, including pricing comparison, dynamic search operations, and Stripe integration endpoints. |
| auth | The auth directory manages user authentication functionality, with OAuth provider integrations and callback processing logic handled in the oauth subdirectory. |
| billing | The billing directory contains a SvelteKit server route that proxies authenticated POST requests to a backend billing upgrade endpoint, validating user tokens and returning either the upstream response or a 503 error if the service is unavailable. |
| console | The console directory is a SvelteKit application section containing server-side logic for core platform features including API key management, billing administration, search index configuration, user onboarding, and account verification workflows. |
| dashboard | — |
| dev_editor_dialog_demo | — |
| forgot-password | — |
| health | — |
| login | — |
| logout | — |
| pricing | — |
| reset-password | — |
| signup | — |
| status | This directory contains TypeScript contract definitions for status-related functionality, specifically a status contract stub file that likely defines the interface or types for status operations. |
| status | The status directory contains TypeScript contract definitions for status-related functionality. |
| verify-email | — |
<!-- [scrai:end] -->
