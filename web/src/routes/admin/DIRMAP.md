<!-- [scrai:start] -->
## admin

| File | Summary |
| --- | --- |
| +layout.server.ts | Stub summary for +layout.server.ts. |

| Directory | Summary |
| --- | --- |
| alerts | The alerts directory contains the server-side route handler for an admin alerts page, currently with a stub implementation. |
| billing | Admin billing page server handler that loads all tenant invoices enriched with customer details and provides actions to run batch billing for a specific month and bulk finalize selected invoices. |
| cold | — |
| customers | This directory contains the admin customers section of the web console, with a main page route handler, shared test fixtures for customer detail components, and a dynamic [id] subdirectory that manages server-side logic for individual customer detail pages including form submissions and data loading. |
| alerts | The admin alerts page loads up to 100 alert records from the admin client, optionally filtered by severity level (info, warning, or critical) from URL query parameters, and gracefully returns an empty array on fetch failure. |
| billing | This SvelteKit server page for the admin billing interface loads invoices across all tenants and provides actions to run batch billing for a specific month or bulk-finalize multiple invoices, with utilities for month validation and invoice sorting. |
| cold | — |
| customers | The customers directory contains admin customer management pages and related test fixtures for a SvelteKit application, with a main page handler and nested routing for individual customer details. |
| end-impersonation | — |
| fleet | — |
| login | — |
| logout | — |
| migrations | The migrations directory contains a SvelteKit admin page server module that handles backend logic for a migrations management interface, though it appears to be a stub pending full implementation. |
| migrations | Server-side route handler for the admin migrations management page in the SvelteKit web frontend. |
| replicas | — |
<!-- [scrai:end] -->
