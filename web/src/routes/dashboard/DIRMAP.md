<!-- [scrai:start] -->
## dashboard

| File | Summary |
| --- | --- |
| +layout.server.ts | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_1_frontend_test_suite/fjcloud_dev/web/src/routes/dashboard/+layout.server.ts. |
| +page.server.ts | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_1_frontend_test_suite/fjcloud_dev/web/src/routes/dashboard/+page.server.ts. |

| Directory | Summary |
| --- | --- |
| api-keys | — |
| billing | The billing directory contains server-side logic for the billing setup page, with a Stripe setup intent function that returns a client secret for payment configuration while handling customer validation and service availability errors. |
| database | The database directory contains a SvelteKit page server that loads and manages user database instances (AYB) from the API, handling instance provisioning status and providing a delete action with comprehensive error handling for various failure scenarios. |
| indexes | The indexes directory is the dashboard page for managing user indexes, providing server-side logic to fetch user indexes and available regions with session expiration detection. |
| migrate | This server-side handler provides two actions for migrating data from Algolia: listIndexes validates credentials and retrieves available indexes, and migrate initiates the migration process given source credentials and index selection, with robust error handling and response parsing. |
| onboarding | The onboarding page server module loads the user's onboarding status from the API and redirects to the dashboard if complete, while providing actions to create indexes and generate API credentials during the setup flow. |
| settings | — |
<!-- [scrai:end] -->
