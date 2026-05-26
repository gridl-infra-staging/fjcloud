<!-- [scrai:start] -->
## console

| File | Summary |
| --- | --- |
| +layout.server.ts | Stub summary for +layout.server.ts. |
| +page.server.ts | Stub summary for +page.server.ts. |

| Directory | Summary |
| --- | --- |
| account | Provides server-side logic for the account settings page, loading the user profile and handling actions for updating profile, changing password, deleting account, and exporting account data with appropriate error handling and session validation. |
| api-keys | The api-keys directory contains the server-side handler (+page.server.ts) for the API keys management console page. |
| billing | The billing directory provides a Svelte setup page for payment method configuration, with a server load function that creates Stripe setup intents and manages client secrets for payment initialization. |
| indexes | The indexes directory contains SvelteKit server-side routes for the customer console, with a main page handler and a dynamic route for viewing individual index details including dictionary management, document operations, and security configurations. |
| migrate | Server-side page handler for migrating search indexes from Algolia, with actions to list available indexes and initiate migrations while validating credentials and handling API errors. |
| onboarding | The onboarding directory contains a SvelteKit server page module that handles server-side logic for the onboarding flow, likely managing user initialization, form submissions, and session setup. |
| resend-verification | The resend-verification directory contains a SvelteKit server route handler for resending email verification messages to users. |
| settings | — |
<!-- [scrai:end] -->
