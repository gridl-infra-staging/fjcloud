<!-- [scrai:start] -->
## lib

| File | Summary |
| --- | --- |
| admin-client.ts | Stub summary for web/src/lib/admin-client.ts. |
| audit.ts | Stub summary for web/src/lib/audit.ts. |
| experiment_helpers.ts | Stub summary for experiment_helpers.ts. |
| flapjack-search-client.ts | Stub summary for web/src/lib/flapjack-search-client.ts. |
| index-name.ts | Canonical destination index-name rules. |
| landing-pricing.ts | Landing-page pricing helpers. |
| pricing.ts | Shared marketing pricing constants used by the landing page pricing table. |
| public_api.ts | Canonical public API origin used by unauthenticated marketing surfaces. |
| vm-capacity.ts | Stub summary for web/src/lib/vm-capacity.ts. |

| Directory | Summary |
| --- | --- |
| analytics | — |
| api | This directory contains the web frontend's API client library, including the base client class, request/response type definitions that match the Axum backend API, error handling, and utilities for normalizing API responses. |
| api-logs | API-logs provides browser-based API request logging infrastructure with a session-storage-backed store, instrumentation helpers for dashboards, and sanitization/export capabilities. |
| auth | — |
| components | The components directory provides UI utilities for form editing, data migration workflows, and client-side search operations, including dialog normalization/validation, migration eligibility logic, and search analytics with state persistence. |
| error-boundary | The error-boundary directory provides client-side error handling and recovery mechanisms, with client-runtime managing error boundaries in the runtime environment and recovery-copy handling fallback messaging during error states. |
| events | The events directory provides time-series bucketing for debug events, grouping them into adaptive time buckets (ranging from 15-second to 1-hour granularity) and counting total, successful (HTTP 200), and error responses within each bucket. |
| http | The http directory contains utilities for parsing and handling the Retry-After HTTP header, including functions to extract retry-after seconds from response headers and validate/normalize retry-after values. |
| recommendations | The recommendations directory provides configuration and validation utilities for Algolia-based product recommendations in the customer dashboard, supporting five models (related products, bought together, trending items, trending facets, and looking similar). |
| rules | — |
| search_templates | — |
| server | This directory contains authentication and session management utilities, including error mapping for login failures, impersonation helpers with return-path validation, and retry logic for transient API calls. |
| synonyms | — |
| utils | The utils directory contains a focus_trap.ts module that provides focus trapping functionality, likely for managing keyboard focus within UI components for accessibility purposes. |
<!-- [scrai:end] -->
