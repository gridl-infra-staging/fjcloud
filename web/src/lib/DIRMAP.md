<!-- [scrai:start] -->
## lib

| File | Summary |
| --- | --- |
| admin-client.ts | Stub summary for admin-client.ts. |
| experiment_helpers.ts | Stub summary for experiment_helpers.ts. |
| flapjack-search-client.ts | Stub summary for web/src/lib/flapjack-search-client.ts. |
| landing-pricing.ts | Landing-page pricing helpers. |
| pricing.ts | Shared marketing pricing constants used by the landing page pricing table. |
| public_api.ts | Canonical public API origin used by unauthenticated marketing surfaces. |

| Directory | Summary |
| --- | --- |
| analytics | — |
| api | This directory contains the TypeScript API client library for the web frontend, providing base client classes, type definitions for Axum API responses and requests, and error handling for API communication. |
| api-logs | This directory provides browser-based API logging infrastructure for the dashboard, including a session-storage-backed log store with sanitization and export capabilities. |
| auth | — |
| components | This directory contains UI component utilities including EditorDialog normalization and validation logic, plus client-side search functionality with support for search-as-you-type, analytics tracking, persisted search choices, and URL state management. |
| error-boundary | The error-boundary directory provides client-side error handling and recovery mechanisms, with client-runtime.ts managing runtime error interception and recovery-copy.ts handling error state persistence or recovery operations. |
| events | I need to examine the actual contents of the events directory to provide an accurate summary. |
| http | The http directory contains utilities for parsing and handling HTTP Retry-After headers, including functions to parse retry-after delay values in seconds from various formats and to extract or construct Retry-After header values for HTTP responses. |
| recommendations | The recommendations directory contains configuration for a recommendations feature, with a primary config.ts file that likely defines settings or behavior for recommendation logic. |
| rules | — |
| search_templates | — |
| server | This directory contains authentication and session management utilities, including error classification for login flows, admin session handling, impersonation validation, and transient API retry logic. |
| synonyms | — |
| utils | The utils directory contains a focus_trap utility module that manages keyboard focus trapping for UI components, likely used to confine focus within modals or overlays. |
| api | API client library for the SvelteKit frontend, providing TypeScript types for request/response communication with the Axum backend, a base client class for shared functionality, and request error handling. |
| api-logs | The api-logs directory provides browser-side API instrumentation and logging for the dashboard, including a session-storage-backed log store with sanitization, export capabilities, and cURL generation. |
| auth | — |
| components | The components directory contains UI dialog and form utilities, including editor dialog normalization and validation logic, alongside a search module that implements client-side search functionality with analytics tracking, browser persistence, and URL state management. |
| error-boundary | Error-boundary provides client-side error handling and recovery functionality, with runtime error catching logic and recovery messaging for displaying fallback UI when errors occur in the application. |
| events | — |
| http | The http directory contains utilities for parsing and formatting the HTTP Retry-After header, providing functions to extract retry delay seconds from response headers and validate/normalize retry-after values. |
| recommendations | I don't have the actual contents of the `config.ts` file. |
| rules | — |
| search_templates | — |
| server | The server directory contains authentication and session management utilities, including error classification for auth failures, impersonation helpers with return-path validation, and transient API retry logic. |
| synonyms | — |
| utils | The utils directory contains focus_trap.ts, a utility module for managing keyboard focus restriction within DOM elements, commonly used in modals and dialogs for accessibility compliance. |
<!-- [scrai:end] -->
