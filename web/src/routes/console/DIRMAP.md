<!-- [scrai:start] -->
## console

| File | Summary |
| --- | --- |
| +layout.server.ts | Stub summary for +layout.server.ts. |
| +page.server.ts | Stub summary for +page.server.ts. |

| Directory | Summary |
| --- | --- |
| account | Provides server-side logic for the account settings page, loading the user profile and handling actions for updating profile, changing password, deleting account, and exporting account data with appropriate error handling and session validation. |
| api-keys | — |
| billing | The billing directory provides a Svelte setup page for payment method configuration, with a server load function that creates Stripe setup intents and manages client secrets for payment initialization. |
| indexes | This directory provides the backend server logic for the dashboard's indexes feature, including a page handler that fetches user indexes and available regions with session management, plus subdirectories containing server-side handlers for managing individual indexes (dictionaries, documents, security configuration, and web frontend integration). |
| migrate | Server-side page handler for migrating search indexes from Algolia, with actions to list available indexes and initiate migrations while validating credentials and handling API errors. |
| onboarding | The onboarding directory contains a SvelteKit server page module that handles server-side logic for the onboarding flow, likely managing user initialization, form submissions, and session setup. |
| resend-verification | The resend-verification directory contains a SvelteKit server route handler for resending email verification messages to users. |
| settings | — |
<!-- [scrai:end] -->
