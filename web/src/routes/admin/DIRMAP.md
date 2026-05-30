<!-- [scrai:start] -->
## admin

| File | Summary |
| --- | --- |
| +layout.server.ts | Stub summary for +layout.server.ts. |

| Directory | Summary |
| --- | --- |
| alerts | This directory contains the admin alerts page route for the SvelteKit frontend, with a server-side handler that currently lacks documentation. |
| billing | The billing directory contains a SvelteKit server component for the billing admin page that requires implementation. |
| cold | — |
| customers | Admin customer management section containing SvelteKit page routes for customer details and related operations, with shared test fixtures supporting component testing across the admin customer detail views. |
| alerts | This module implements a SvelteKit page server loader for the admin alerts interface that parses a severity filter from URL query parameters and fetches alerts from an admin client API. |
| billing | Admin billing page that loads and displays all tenant invoices with sorting, and provides server actions to run batch billing for a specified month and bulk-finalize selected invoices. |
| cold | — |
| customers | This directory implements the admin customers management interface for the SvelteKit web frontend, including a main page server handler, shared test fixtures for customer detail components, and a dynamic route handler for viewing and managing individual customer data. |
| end-impersonation | — |
| fleet | — |
| login | — |
| logout | — |
| migrations | This SvelteKit server-side route handler manages the admin migrations page, loading both active and recent index migrations from the admin API and providing a server action to trigger new migrations with validation. |
| migrations | This directory contains database schema migrations and an admin interface for managing data migrations. |
| replicas | — |
<!-- [scrai:end] -->
