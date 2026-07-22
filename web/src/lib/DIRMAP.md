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
| api | This directory contains the frontend API client library, including shared base classes for HTTP communication, type definitions for API requests and responses matching the backend Axum server, error handling, and utilities for client data normalization. |
| api-logs | Browser-side API logging utilities that capture, store, sanitize, and export HTTP request data using session storage. |
| auth | — |
| components | This components directory contains UI and utility modules for a web application's core features, including editor dialog logic for normalization and validation, data migration eligibility and job management, and client-side search functionality with analytics tracking and state persistence. |
| error-boundary | The error-boundary directory contains client-side error handling logic with a runtime component for managing errors on the client and a recovery mechanism for copying or restoring state during error scenarios. |
| events | The eventBuckets module provides utilities to aggregate debug events into time-based buckets with adaptive sizing based on the viewing window, tracking total events and counts of successful versus error responses for charting purposes. |
| http | This directory contains HTTP utility functions, with retry_after.ts handling retry timing and backoff logic based on HTTP response headers. |
| recommendations | The recommendations directory contains configuration code, with a config.ts module providing setup and configuration for the recommendations feature. |
| rules | — |
| search_templates | — |
| server | Server-side utilities for authentication, session management, and authorization, including error mapping for login failures, impersonation helpers for access validation, and transient API retry logic. |
| synonyms | — |
| utils | This utils directory contains focus management utilities for modal and trap focus patterns. |
<!-- [scrai:end] -->
