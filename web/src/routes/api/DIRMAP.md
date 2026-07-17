<!-- [scrai:start] -->
## api

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| pricing | The pricing directory contains a SvelteKit server route handler that processes pricing comparison POST requests, validating inputs and delegating to an API client with a fallback to a public canonical API for local development scenarios. |
| search | This API route handles search-related requests and events, logging interactions with search preview results while validating payloads and session information before forwarding to the backend API. |
| stripe | — |
| pricing | The pricing directory contains API routes for the customer-facing dashboard, including a compare endpoint that handles pricing comparison operations via SvelteKit's server routing. |
| search | This directory provides SvelteKit API routes for search operations on dynamically-named queries, with a server handler and events subdirectory for managing search-related event processing. |
| stripe | The stripe directory contains SvelteKit server endpoints for Stripe integration, including a publishable-key endpoint that handles API operations related to Stripe publishable keys. |
<!-- [scrai:end] -->
