# Support Email Surface Audit

Created: 2026-06-04T06:37:33Z

Purpose: replace the stale 20260604T053841Z audit, which predated the signup
and verify-email support-mailto fixes.

Command:

```bash
rg -n "LEGAL_SUPPORT_MAILTO|SUPPORT_EMAIL" web/src/routes/signup web/src/routes/verify-email/[token]
```

Output:

```text
web/src/routes/signup/signup.test.ts:10:import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';
web/src/routes/signup/signup.test.ts:55:		const supportLink = screen.getByRole('link', { name: SUPPORT_EMAIL });
web/src/routes/signup/signup.test.ts:56:		expect(supportLink).toHaveAttribute('href', LEGAL_SUPPORT_MAILTO);
web/src/routes/signup/signup.test.ts:57:		expect(supportLink.closest('p')).toHaveTextContent(`Need help? Contact ${SUPPORT_EMAIL}`);
web/src/routes/verify-email/[token]/verify-email.test.ts:4:import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';
web/src/routes/verify-email/[token]/verify-email.test.ts:48:		const supportLink = screen.getByRole('link', { name: SUPPORT_EMAIL });
web/src/routes/verify-email/[token]/verify-email.test.ts:49:		expect(supportLink).toHaveAttribute('href', LEGAL_SUPPORT_MAILTO);
web/src/routes/verify-email/[token]/verify-email.test.ts:51:			`If the problem persists, contact ${SUPPORT_EMAIL}.`
web/src/routes/signup/+page.svelte:4:	import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';
web/src/routes/signup/+page.svelte:146:				href={LEGAL_SUPPORT_MAILTO}
web/src/routes/signup/+page.svelte:149:				{SUPPORT_EMAIL}
web/src/routes/verify-email/[token]/+page.svelte:3:	import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';
web/src/routes/verify-email/[token]/+page.svelte:64:					href={LEGAL_SUPPORT_MAILTO}
web/src/routes/verify-email/[token]/+page.svelte:67:					{SUPPORT_EMAIL}
```

Findings:

- Covered: `web/src/routes/signup/+page.svelte` imports
  `LEGAL_SUPPORT_MAILTO` and `SUPPORT_EMAIL` and renders the help mailto link.
- Covered: `web/src/routes/signup/signup.test.ts` asserts the link text and
  `LEGAL_SUPPORT_MAILTO` href.
- Covered: `web/src/routes/verify-email/[token]/+page.svelte` imports
  `LEGAL_SUPPORT_MAILTO` and `SUPPORT_EMAIL` and renders the failure help link.
- Covered: `web/src/routes/verify-email/[token]/verify-email.test.ts` asserts
  the link text and `LEGAL_SUPPORT_MAILTO` href.
- Uncovered: none for the Stage 4 signup and verify-email support-mailto scope.
