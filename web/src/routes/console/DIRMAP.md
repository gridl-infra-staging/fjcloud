<!-- [scrai:start] -->
## console

| File | Summary |
| --- | --- |
| +layout.server.ts | Stub summary for +layout.server.ts. |
| +page.server.ts | Stub summary for +page.server.ts. |

| Directory | Summary |
| --- | --- |
| account | The account directory contains server-side page logic for account management functionality, primarily implemented through the +page.server.ts SvelteKit component handler. |
| api-keys | This SvelteKit page server handles the API keys management dashboard, loading existing keys and indexes while supporting creation of new keys with optional scope, rate-limit, expiration, and source-restriction constraints, and revocation of existing keys. |
| billing | This directory contains billing page handlers, with a setup module that manages Stripe setup intents for payment method configuration by creating intents and returning client secrets to the frontend. |
| indexes | The indexes directory implements the console interface for managing search indexes, with server-side logic and modular management features for analytics, chat, documents, recommendations, rules, security, and other index-specific functionality. |
| migrate | This directory contains a SvelteKit page for migration functionality, with server-side logic defined in +page.server.ts to handle migration-related operations and data flow. |
| onboarding | The onboarding directory contains a SvelteKit page server implementation with a stub summary, likely handling server-side logic for the initial user onboarding flow. |
| resend-verification | Handles resend verification email requests for user account verification flows. |
| settings | — |
<!-- [scrai:end] -->
