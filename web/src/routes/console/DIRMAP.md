<!-- [scrai:start] -->
## console

| File | Summary |
| --- | --- |
| +layout.server.ts | Stub summary for +layout.server.ts. |
| +page.server.ts | Stub summary for +page.server.ts. |

| Directory | Summary |
| --- | --- |
| account | The account directory contains a SvelteKit route with a server-side page component that handles data loading and server actions for the account management page. |
| api-keys | The api-keys directory contains a SvelteKit server-side route for managing API keys, with route handlers defined in +page.server.ts. |
| billing | The billing directory contains SvelteKit server-side routes for the console's billing configuration interface. |
| indexes | This directory contains the SvelteKit index console interface, with a dynamic [name] route that organizes server-side management modules and UI components for various domain-specific handlers including analytics, chat, documents, and experiments. |
| migrate | The migrate directory contains a SvelteKit server-side route handler that appears to be a stub awaiting implementation. |
| onboarding | The onboarding directory contains a +page.server.ts file that serves as the server-side handler for an onboarding route in the SvelteKit application. |
| resend-verification | The resend-verification directory contains a SvelteKit server route handler that appears to manage email verification logic, though the implementation details are currently documented as a stub. |
| account | The account directory contains a SvelteKit server-side page component that likely handles the account management route for the customer-facing dashboard. |
| api-keys | The api-keys directory contains a SvelteKit server-side route page handler for managing API keys in the fjcloud customer console. |
| billing | The billing directory contains SvelteKit pages for customer billing management, including a setup component that creates Stripe setup intents through the API to enable secure payment configuration. |
| indexes | The indexes directory contains the SvelteKit console dashboard interface for managing various index features including documents, analytics, chat, dictionaries, events, personalization, recommendations, rules, and security sources. |
| migrate | This SvelteKit server-side module handles Algolia-to-fjcloud index migration, providing two form actions: `listIndexes` to fetch available Algolia indexes with user credentials, and `migrate` to initiate a migration from a selected index. |
| onboarding | This directory contains the onboarding page route handler for a SvelteKit application. |
| resend-verification | SvelteKit POST endpoint that resends a verification email by calling the backend API with the user's token and returns appropriate retry-after headers for rate limiting. |
| settings | — |
<!-- [scrai:end] -->
