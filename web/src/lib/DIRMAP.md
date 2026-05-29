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
| api | This directory contains a TypeScript API client implementation with a shared base class for common client functionality, a concrete client implementation, and associated type definitions. |
| api-logs | The api-logs directory provides browser-side API logging infrastructure for the dashboard, including instrumentation of SvelteKit form and fetch requests, a sanitization layer to remove sensitive data, and utilities for log export and debugging. |
| auth | The auth directory contains JWT token handling logic for the web frontend. |
| components | The components directory contains editor dialog utilities for normalization and validation, along with search functionality supporting analytics tracking, user preferences, and URL state management for search parameters and filters. |
| error-boundary | The error-boundary directory contains client-side error handling and recovery logic, with client-runtime managing the runtime error detection and recovery-copy handling error messages and user-facing recovery instructions. |
| events | The events directory contains event-related utilities, specifically eventBuckets.ts which handles organizing or grouping events into buckets for processing or categorization purposes. |
| http | The http directory contains utilities for HTTP protocol handling, specifically a retry_after module for managing retry-after header parsing and exponential backoff logic in HTTP responses. |
| recommendations | The recommendations directory contains configuration code for the recommendations feature or module. |
| rules | The rules directory contains helper utilities for managing rule-related functionality, with ruleHelpers.ts providing support functions for rule operations. |
| search_templates | — |
| server | The server directory contains authentication and session management utilities, including error classification for auth failures, impersonation validation helpers, and retry logic. |
| synonyms | — |
| utils | This utils directory contains client-side utility functions for the web frontend, including UI focus management (focus_trap.ts) and product merchandising logic (merchandising.ts). |
| api | The api directory contains TypeScript modules for API client functionality, centered around a shared base class for API clients with accompanying client implementation and type definitions. |
| api-logs | This directory implements browser-side API logging for the dashboard, capturing and sanitizing SvelteKit form submissions and fetch requests to create instrumented log entries. |
| auth | The auth directory contains JWT utility functions for client-side token validation, including decoding JWT payloads, verifying HS256 signatures with timing-safe comparison, and checking token expiration. |
| components | This components directory contains editor dialog utilities for normalization and validation, along with search functionality utilities that manage search state, analytics, and user preferences for the web frontend. |
| error-boundary | The error-boundary directory contains client-side error handling and recovery functionality, with client-runtime.ts managing runtime error interception and recovery-copy.ts providing user-facing messaging for error recovery scenarios. |
| events | The events directory contains event management utilities, including eventBuckets.ts which handles organizing or categorizing events into logical buckets for processing or analysis. |
| http | The http directory contains HTTP utilities, including retry_after.ts which handles retry logic and backoff mechanisms for HTTP requests. |
| recommendations | The recommendations directory contains configuration for recommendations functionality, with a config.ts file that handles the setup or settings related to the recommendations feature. |
| rules | The rules directory contains ruleHelpers.ts, which provides utility functions for managing and working with rules throughout the application. |
| search_templates | — |
| server | This directory contains authentication and session management utilities for the server, including error classification and HTTP response mapping for login failures, impersonation helpers with return-path validation, and transient API retry logic. |
| synonyms | — |
| utils | The utils directory contains focus management and UI utility helpers for the web frontend, including focus trap functionality and merchandising/pricing-related utilities supporting the dashboard and billing interfaces. |
<!-- [scrai:end] -->
