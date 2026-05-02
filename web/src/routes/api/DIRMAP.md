<!-- [scrai:start] -->
## api

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| pricing | The pricing directory contains a SvelteKit API endpoint for pricing comparison functionality. |
| search | This SvelteKit server route handles POST requests to execute searches against Flapjack indexes, validating authentication and parsing batched search requests before delegating to the executeIndexSearch service. |
| stripe | The stripe directory provides API endpoints for Stripe integration, specifically a publishable-key endpoint that retrieves and serves the Stripe publishable key to authenticated users by proxying requests to the backend billing service. |
<!-- [scrai:end] -->
