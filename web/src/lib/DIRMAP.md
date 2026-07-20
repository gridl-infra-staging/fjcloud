<!-- [scrai:start] -->
## lib

| File | Summary |
| --- | --- |
| admin-client.ts | Stub summary for admin-client.ts. |
| experiment_helpers.ts | Stub summary for experiment_helpers.ts. |
| flapjack-search-client.ts | Stub summary for web/src/lib/flapjack-search-client.ts. |
| index-name.ts | Canonical destination index-name rules. |
| landing-pricing.ts | Landing-page pricing helpers. |
| pricing.ts | Shared marketing pricing constants used by the landing page pricing table. |
| public_api.ts | Canonical public API origin used by unauthenticated marketing surfaces. |

| Directory | Summary |
| --- | --- |
| analytics | — |
| api | This directory contains the web frontend's API client library for communicating with the Axum backend, including base client classes, typed request/response definitions, and error handling utilities. |
| api-logs | API logging and instrumentation utilities for the dashboard frontend, providing a browser-based API log store with session persistence, sanitization of sensitive data, and helpers for exporting and instrumenting API calls. |
| auth | — |
| components | This components directory contains SvelteKit UI components and utilities for editor dialogs, migration workflow management with provider and job handling, and search functionality with analytics tracking and local persistence. |
| error-boundary | Handles browser runtime errors (uncaught exceptions and unhandled rejections) by normalizing failures into a standard format and reporting them to the backend, while generating user-friendly error messages and deterministic support references based on error scope and HTTP status. |
| events | The events directory contains utilities for managing event bucketing, with eventBuckets.ts providing the primary implementation. |
| http | The http directory contains HTTP utilities, with retry_after.ts handling parsing and logic for the HTTP Retry-After header to manage request retry behavior. |
| recommendations | The recommendations directory contains configuration code, specifically a TypeScript config file that appears to handle settings or setup for a recommendations module or feature. |
| rules | — |
| search_templates | — |
| server | Server-side authentication and session utilities, providing error classification for login failures, impersonation helpers for return-path validation, and retry logic for transient API failures. |
| synonyms | — |
| utils | The utils directory contains focus trap utilities for managing keyboard focus behavior in UI components. |
<!-- [scrai:end] -->
