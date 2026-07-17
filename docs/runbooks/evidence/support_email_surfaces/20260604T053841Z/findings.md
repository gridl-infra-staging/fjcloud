# Support Email Surface Audit

Created: 2026-06-04T05:38:41Z

Command:

```bash
rg -n "SUPPORT_EMAIL|support@flapjack\\.foo|LEGAL_SUPPORT_MAILTO" web/src
```

Output:

```text
web/src/routes/error.test.ts:3:import { SUPPORT_EMAIL } from '$lib/format';
web/src/routes/error.test.ts:186:		expect(screen.getByRole('link', { name: SUPPORT_EMAIL })).toHaveAttribute(
web/src/routes/error.test.ts:188:			expect.stringContaining(`mailto:${SUPPORT_EMAIL}`)
web/src/routes/error.test.ts:205:		expect(screen.getByRole('link', { name: SUPPORT_EMAIL })).toHaveAttribute(
web/src/routes/error.test.ts:207:			expect.stringContaining(`mailto:${SUPPORT_EMAIL}`)
web/src/routes/error.test.ts:254:			expect(screen.getByRole('link', { name: SUPPORT_EMAIL })).toHaveAttribute(
web/src/routes/error.test.ts:256:				expect.stringContaining(`mailto:${SUPPORT_EMAIL}`)
web/src/routes/dpa/dpa.test.ts:5:import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';
web/src/routes/dpa/dpa.test.ts:49:				`To request a signed DPA, email ${SUPPORT_EMAIL} and reference the relevant customer account.`
web/src/routes/dpa/dpa.test.ts:57:			name: exactNameMatcher(SUPPORT_EMAIL)
web/src/routes/dpa/dpa.test.ts:62:		expect(signedDpaRequestLink).toHaveAttribute('href', LEGAL_SUPPORT_MAILTO);
web/src/routes/console/onboarding/onboarding.test.ts:450:		// Contact support link uses the shared SUPPORT_EMAIL constant
web/src/routes/console/onboarding/onboarding.test.ts:453:		expect(contactLink).toHaveAttribute('href', 'mailto:support@flapjack.foo');
web/src/routes/dpa/+page.svelte:5:		LEGAL_SUPPORT_MAILTO,
web/src/routes/dpa/+page.svelte:6:		SUPPORT_EMAIL
web/src/routes/dpa/+page.svelte:85:				href={LEGAL_SUPPORT_MAILTO}
web/src/routes/dpa/+page.svelte:88:				{SUPPORT_EMAIL}
web/src/routes/console/onboarding/+page.svelte:7:	import { REGIONS, SUPPORT_EMAIL } from '$lib/format';
web/src/routes/console/onboarding/+page.svelte:392:								href="mailto:{SUPPORT_EMAIL}"
web/src/routes/terms/+page.svelte:5:		LEGAL_SUPPORT_MAILTO,
web/src/routes/terms/+page.svelte:6:		SUPPORT_EMAIL
web/src/routes/terms/+page.svelte:108:				href={LEGAL_SUPPORT_MAILTO}
web/src/routes/terms/+page.svelte:111:				{SUPPORT_EMAIL}
web/src/routes/privacy/+page.svelte:5:		LEGAL_SUPPORT_MAILTO,
web/src/routes/privacy/+page.svelte:6:		SUPPORT_EMAIL
web/src/routes/privacy/+page.svelte:97:				href={LEGAL_SUPPORT_MAILTO}
web/src/routes/privacy/+page.svelte:100:				{SUPPORT_EMAIL}
web/src/routes/console/billing/billing.server.test.ts:3:import { SUPPORT_EMAIL } from '$lib/format';
web/src/routes/console/billing/billing.server.test.ts:417:				message: `Billing is being set up for your account. Please contact ${SUPPORT_EMAIL} if this persists.`
web/src/routes/console/billing/billing.test.ts:4:import { SUPPORT_EMAIL } from '$lib/format';
web/src/routes/console/billing/billing.test.ts:164:			name: `Contact ${SUPPORT_EMAIL} to cancel`
web/src/routes/console/billing/billing.test.ts:166:		expect(cancelSubscriptionLink).toHaveAttribute('href', `mailto:${SUPPORT_EMAIL}`);
web/src/routes/console/billing/+page.svelte:5:	import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';
web/src/routes/console/billing/+page.svelte:169:						href={LEGAL_SUPPORT_MAILTO}
web/src/routes/console/billing/+page.svelte:171:						{SUPPORT_EMAIL}
web/src/routes/console/billing/+page.svelte:180:						href={LEGAL_SUPPORT_MAILTO}
web/src/routes/console/billing/+page.svelte:182:						Contact {SUPPORT_EMAIL} to cancel
web/src/routes/console/billing/+page.server.ts:9:import { SUPPORT_EMAIL } from '$lib/format';
web/src/routes/console/billing/+page.server.ts:18:const BILLING_SETUP_ERROR = `Billing is being set up for your account. Please contact ${SUPPORT_EMAIL} if this persists.`;
web/src/routes/status/status.test.ts:146:			expect.stringContaining('mailto:support@flapjack.foo')
web/src/routes/console/+layout.svelte:7:	import { SUPPORT_EMAIL } from '$lib/format';
web/src/routes/console/+layout.svelte:27:	const supportMailtoHref = `mailto:${SUPPORT_EMAIL}`;
web/src/routes/legal_page_test_helpers.test.ts:8:	LEGAL_SUPPORT_MAILTO,
web/src/routes/legal_page_test_helpers.test.ts:9:	SUPPORT_EMAIL
web/src/routes/legal_page_test_helpers.test.ts:25:			<a href="${LEGAL_SUPPORT_MAILTO}">Support</a>
web/src/routes/legal_page_test_helpers.test.ts:34:			<a href="${LEGAL_SUPPORT_MAILTO}">${SUPPORT_EMAIL}</a>
web/src/routes/+layout.svelte:6:	import { SUPPORT_EMAIL } from '$lib/format';
web/src/routes/+layout.svelte:123:				<p>&copy; {new Date().getFullYear()} Flapjack Cloud. Contact: {SUPPORT_EMAIL}</p>
web/src/routes/console/error.test.ts:3:import { SUPPORT_EMAIL } from '$lib/format';
web/src/routes/console/error.test.ts:163:		expect(screen.getByRole('link', { name: SUPPORT_EMAIL })).toHaveAttribute(
web/src/routes/console/error.test.ts:165:			expect.stringContaining(`mailto:${SUPPORT_EMAIL}`)
web/src/routes/console/error.test.ts:182:		expect(screen.getByRole('link', { name: SUPPORT_EMAIL })).toHaveAttribute(
web/src/routes/console/error.test.ts:184:			expect.stringContaining(`mailto:${SUPPORT_EMAIL}`)
web/src/routes/console/error.test.ts:231:			expect(screen.getByRole('link', { name: SUPPORT_EMAIL })).toHaveAttribute(
web/src/routes/console/error.test.ts:233:				expect.stringContaining(`mailto:${SUPPORT_EMAIL}`)
web/src/routes/console/layout.test.ts:8:import { SUPPORT_EMAIL } from '$lib/format';
web/src/routes/console/layout.test.ts:523:		expect(desktopSupportLink).toHaveAttribute('href', `mailto:${SUPPORT_EMAIL}`);
web/src/routes/console/layout.test.ts:533:		expect(mobileSupportLink).toHaveAttribute('href', `mailto:${SUPPORT_EMAIL}`);
web/src/routes/console/layout.test.ts:567:			expect.stringContaining('mailto:support@flapjack.foo')
web/src/lib/format.ts:189:export const SUPPORT_EMAIL = 'support@flapjack.foo';
web/src/lib/format.ts:191:export const LEGAL_SUPPORT_MAILTO = `mailto:${SUPPORT_EMAIL}`;
web/src/lib/format.ts:193:export const BETA_FEEDBACK_MAILTO = `mailto:${SUPPORT_EMAIL}?subject=${encodeURIComponent('Flapjack Cloud beta feedback')}`;
web/src/lib/error-boundary/recovery-copy.test.ts:2:import { SUPPORT_EMAIL } from '$lib/format';
web/src/lib/error-boundary/recovery-copy.test.ts:20:		expect(firstCopy.supportEmail).toBe(SUPPORT_EMAIL);
web/src/lib/error-boundary/recovery-copy.test.ts:24:		expect(firstCopy.supportMailtoHref).toContain(`mailto:${SUPPORT_EMAIL}`);
web/src/lib/error-boundary/recovery-copy.test.ts:35:		expect(copy.supportEmail).toBe(SUPPORT_EMAIL);
web/src/lib/error-boundary/SupportReferenceBlock.test.ts:3:import { SUPPORT_EMAIL } from '$lib/format';
web/src/lib/error-boundary/SupportReferenceBlock.test.ts:8:	it('renders one support reference and uses SUPPORT_EMAIL for the mailto link', () => {
web/src/lib/error-boundary/SupportReferenceBlock.test.ts:18:		expect(screen.getByRole('link', { name: SUPPORT_EMAIL })).toHaveAttribute(
web/src/lib/error-boundary/SupportReferenceBlock.test.ts:20:			expect.stringContaining(`mailto:${SUPPORT_EMAIL}`)
web/src/lib/error-boundary/recovery-copy.ts:4:import { SUPPORT_EMAIL } from '$lib/format';
web/src/lib/error-boundary/recovery-copy.ts:173:		supportEmail: SUPPORT_EMAIL,
web/src/lib/error-boundary/recovery-copy.ts:174:		supportMailtoHref: `mailto:${SUPPORT_EMAIL}?subject=${encodeURIComponent(
web/src/lib/components/SiteFooter.svelte:3:	import { SUPPORT_EMAIL } from '$lib/format';
web/src/lib/components/SiteFooter.svelte:10:		<p>&copy; {new Date().getFullYear()} Flapjack Cloud. Contact: {SUPPORT_EMAIL}</p>
web/src/lib/components/BetaSupportBadge.svelte:3:	import { BETA_FEEDBACK_MAILTO, SUPPORT_EMAIL } from '$lib/format';
web/src/lib/components/BetaSupportBadge.svelte:48:		href={`mailto:${SUPPORT_EMAIL}`}
web/src/lib/components/BetaPill.svelte:3:	import { BETA_FEEDBACK_MAILTO, SUPPORT_EMAIL } from '$lib/format';
web/src/lib/components/BetaPill.svelte:26:		href={`mailto:${SUPPORT_EMAIL}`}
```

Findings:

- Covered: `web/src/routes/+error.svelte` imports `SupportReferenceBlock` at line 4 and renders it at line 36. `web/src/lib/error-boundary/recovery-copy.ts:173-176` supplies `SUPPORT_EMAIL` and a support-reference mailto href.
- Covered: `web/src/routes/console/billing/+page.svelte` imports `LEGAL_SUPPORT_MAILTO` and `SUPPORT_EMAIL` at line 5 and renders support mailto links at lines 169-182.
- Covered: public legal pages (`dpa`, `terms`, `privacy`) use `LEGAL_SUPPORT_MAILTO` for hrefs and `SUPPORT_EMAIL` for visible text.
- Covered: console layout, onboarding, status tests, and shared beta/footer components already reference support email constants or mailto links.
- Uncovered: `web/src/routes/signup/+page.svelte` has no `SUPPORT_EMAIL` import and no support mailto in the form error or page help text.
- Uncovered: `web/src/routes/verify-email/[token]/+page.svelte` has no `SUPPORT_EMAIL` import and the failure branch has no support mailto.
- Constants verified: `web/src/lib/format.ts:189-191` exports `SUPPORT_EMAIL` and `LEGAL_SUPPORT_MAILTO`; stage changes should import those instead of hardcoding the support address.
