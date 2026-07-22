<!-- [scrai:start] -->
## admin

| File | Summary |
| --- | --- |
| +layout.server.ts | Stub summary for web/src/routes/admin/+layout.server.ts. |

| Directory | Summary |
| --- | --- |
| alerts | This file implements server-side data loading for an admin alerts management page, fetching up to 100 alerts with optional severity filtering (info, warning, critical) based on URL query parameters. |
| billing | Provides server-side logic for the admin billing page, including data loading and form actions for running batch billing and bulk-finalizing invoices, with comprehensive validation and normalization of billing data from the admin API. |
| cold | — |
| customers | Admin interface for customer management, providing detailed views of tenant information including indexes, deployments, usage, and billing data, along with server-side actions for quota management, account suspension, Stripe synchronization, and customer impersonation or deletion. |
| end-impersonation | — |
| fleet | The fleet directory contains the admin interface for managing fleet resources, with a SvelteKit server route handler and associated test fixtures for fleet administration functionality. |
| login | — |
| logout | — |
| migrations | Loads active and recent migrations from an admin client for display on an admin dashboard page. |
| replicas | — |
<!-- [scrai:end] -->
