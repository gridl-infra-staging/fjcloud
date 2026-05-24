<!-- [scrai:start] -->
## console

| File | Summary |
| --- | --- |
| +layout.server.ts | Stub summary for +layout.server.ts. |
| +page.server.ts | Stub summary for +page.server.ts. |

| Directory | Summary |
| --- | --- |
| account | The account directory contains server-side logic for the user account management page, likely handling account settings, profile information, and related operations. |
| api-keys | — |
| billing | The billing directory contains SvelteKit server page logic for managing payment configuration, including a setup page that loads Stripe setup intents to allow users to configure their payment methods with error handling for unavailable billing or missing customer state. |
| indexes | The indexes directory implements fjcloud's dashboard console for managing customer indexes, with a main page that fetches user indexes and available regions, and detail routes that handle dictionary operations, document management, and security configuration. |
| migrate | The migrate directory contains a SvelteKit page server file that appears to be a stub implementation, likely for a migration-related page in the web application. |
| onboarding | This is a SvelteKit onboarding route directory containing a server-side page component. |
| resend-verification | A POST endpoint that resends a verification email to the authenticated user, returning the API response with retry-after headers or appropriate error responses with retry-after information when the request fails. |
| settings | — |
<!-- [scrai:end] -->
