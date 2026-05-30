<!-- [scrai:start] -->
## lib

| File | Summary |
| --- | --- |
| admin-client.ts | Stub summary for admin-client.ts. |
| experiment_helpers.ts | Stub summary for experiment_helpers.ts. |
| flapjack-search-client.ts | Stub summary for flapjack-search-client.ts. |
| landing-pricing.ts | Landing-page pricing helpers. |
| pricing.ts | Stub summary for pricing.ts. |
| public_api.ts | Canonical public API origin used by unauthenticated marketing surfaces. |
| stripe.ts | Stub summary for stripe.ts. |

| Directory | Summary |
| --- | --- |
| analytics | — |
| api | The api directory contains TypeScript files for building API clients, including a shared base class for client implementations, a concrete client, and associated type definitions. |
| api-logs | The api-logs directory provides browser-based API logging and instrumentation for the dashboard, capturing and sanitizing SvelteKit form submissions and fetch requests into a centralized store. |
| auth | This directory contains authentication utilities, including JWT token handling for encoding, decoding, and validating authentication credentials in the web frontend. |
| components | The components directory contains EditorDialog modules for normalization and validation, along with a search subdirectory that provides utilities for managing search feature state, persistence, and analytics. |
| error-boundary | This directory provides error boundary implementations for handling client-side errors, with modules for client runtime management and recovery messaging. |
| events | The events directory contains eventBuckets.ts, which handles event bucketing functionality. |
| http | The http directory contains utilities for handling HTTP-related functionality, including retry-after logic for managing rate limiting and response delays. |
| recommendations | The recommendations directory contains configuration code for managing recommendation-related settings and parameters. |
| rules | ruleHelpers.ts contains utility functions for rule processing and manipulation within the rules module. |
| search_templates | — |
| server | The server directory contains authentication and session management utilities, including error classification for auth failures, impersonation helpers with return-path validation, and API retry logic. |
| synonyms | — |
| utils | This directory provides UI utility functions: focus_trap.ts implements keyboard focus management and cycling for modals and dialogs, while merchandising.ts creates search result merchandising rules that pin or hide specific items in search results. |
| api | API client library providing a shared base class for building TypeScript API clients along with type definitions and client implementations. |
| api-logs | This directory contains a browser-side API logging and instrumentation system that captures SvelteKit form submissions and fetch requests, sanitizes sensitive data, and stores them for dashboard diagnostics. |
| auth | The auth directory provides JWT-based authentication utilities for the frontend, including functions to decode JWT tokens, validate HS256 signatures, check expiration, and resolve authenticated users from cookies. |
| components | This components directory provides UI utilities and feature modules, including EditorDialog normalization and validation logic, and a search module that manages client-side state for queries, filters, analytics tracking, and URL-based state management. |
| error-boundary | This directory contains client-side error handling and recovery logic, with utilities for managing error boundaries in the runtime and copy/messaging for error recovery flows. |
| events | The events directory contains eventBuckets.ts, which appears to handle event bucketing logic. |
| http | The http directory contains utilities for HTTP request handling, specifically a retry_after.ts module that manages retry logic based on HTTP Retry-After headers. |
| recommendations | The recommendations directory contains configuration utilities, with config.ts providing setup and environment-based configuration for the recommendations feature. |
| rules | The rules directory provides utility functions for building, validating, and serializing search merchandising rules that control result pinning, hiding, and query parameter modifications. |
| search_templates | — |
| server | This directory contains server-side utilities for authentication and session handling, including error classification for login failures, impersonation helpers with return-path validation, and transient API retry logic for resilience. |
| synonyms | — |
| utils | This utils directory contains helper functions for UI focus management and merchandising/commerce operations. |
<!-- [scrai:end] -->
