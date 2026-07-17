<!-- [scrai:start] -->
## admin

| File | Summary |
| --- | --- |
| +layout.server.ts | Stub summary for web/src/routes/admin/+layout.server.ts. |

| Directory | Summary |
| --- | --- |
| alerts | The alerts directory contains a SvelteKit server-side load function that fetches filtered alert records from an admin client based on severity level (info, warning, critical, or all) and handles fetch failures gracefully. |
| billing | The billing directory contains the server-side logic for the admin billing page, currently implemented as a SvelteKit server component stub. |
| cold | — |
| customers | Admin customer management module for the dashboard, containing a main page server component and a nested dynamic route for viewing individual customer details, with test fixtures for the admin customer detail component. |
| alerts | The alerts directory contains a SvelteKit admin page route with a server-side handler stub for managing alert functionality. |
| billing | This is an admin billing page server component for SvelteKit that loads invoices across all tenants and provides actions to run batch billing for a specific month and bulk finalize invoices. |
| cold | — |
| customers | The customers directory provides administrative functions for managing customer accounts, including viewing customer details, deployments, usage metrics, invoices, and quotas. |
| end-impersonation | — |
| fleet | — |
| login | — |
| logout | — |
| migrations | Server-side handler for the admin migrations dashboard that loads active and recent migrations from the admin client API and provides an action to trigger new migrations with validation for index name and destination VM ID. |
| migrations | The migrations directory contains a SvelteKit admin page server component that handles the backend logic for viewing or managing database migrations in the administration interface. |
| replicas | — |
<!-- [scrai:end] -->
