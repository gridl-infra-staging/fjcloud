<!-- [scrai:start] -->
## api

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| pricing | The pricing directory contains server-side comparison functionality built as a SvelteKit endpoint that processes requests for pricing comparisons. |
| search | The search directory provides API route handlers for search functionality, including a main server endpoint and an events handler that validates search preview results before forwarding them to the backend API. |
| stripe | The stripe directory contains API endpoints for Stripe integration, with a publishable-key endpoint that retrieves the Stripe publishable key from the backend billing service, returning 401 for unauthenticated requests or 503 if the upstream service is unavailable. |
<!-- [scrai:end] -->
