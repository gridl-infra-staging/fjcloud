<!-- [scrai:start] -->
## console

| File | Summary |
| --- | --- |
| +layout.server.ts | Stub summary for +layout.server.ts. |
| +page.server.ts | Stub summary for +page.server.ts. |

| Directory | Summary |
| --- | --- |
| account | Handles server-side logic for the dashboard account settings page, including loading user profile data and processing four actions for updating profile, changing password, deleting account, and exporting account data. |
| api-keys | This SvelteKit server page handles API key management, providing a load function to fetch available API keys and indexes for display, and form actions to create new API keys with configurable scopes, rate limits, and expiration dates, plus a revoke action with idempotency checks. |
| billing | I don't have enough information to provide an accurate summary. |
| indexes | A SvelteKit route directory that provides server-side page handlers and dynamic routes for managing search indexes, with support for analytics, chat, dictionary, events, personalization, recommendations, rules, security, and suggestions features. |
| migrate | The migrate directory contains a SvelteKit server page component for handling data migration operations in the console interface. |
| onboarding | The onboarding directory contains server-side page logic for an onboarding flow. |
| resend-verification | The resend-verification directory contains a SvelteKit server route handler that manages resending verification messages, likely for email verification workflows in the authentication flow. |
| account | — |
| api-keys | The api-keys directory is a SvelteKit page route containing a +page.server.ts file that currently appears to be a stub implementation, likely serving as the server-side logic for an API key management page in the billing platform. |
| billing | The billing directory contains a SvelteKit server page component (+page.server.ts) that is currently a stub, likely serving as a placeholder for billing-related frontend functionality such as invoice display or payment management. |
| indexes | The indexes directory provides server-side management for search index configuration and administration, with the [name] subdirectory containing specialized modules for configuring detailed index features including analytics, chat, personalization, recommendations, security, and more. |
| migrate | The migrate route provides a SvelteKit server load function that fetches Algolia migration availability from the API, returning availability status with a fallback message if the service is temporarily unavailable or the user lacks authentication. |
| onboarding | The onboarding directory contains a SvelteKit page server component that handles server-side logic for the user onboarding flow. |
| resend-verification | The resend-verification directory contains a SvelteKit server endpoint for resending verification requests, likely handling email or identity verification workflows. |
| settings | — |
<!-- [scrai:end] -->
