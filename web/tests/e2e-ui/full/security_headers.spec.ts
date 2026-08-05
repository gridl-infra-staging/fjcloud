import type { Response } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';

test.use({ storageState: { cookies: [], origins: [] } });

const EXPECTED_ENFORCED_CSP_DIRECTIVES = {
	'base-uri': ["'none'"],
	'connect-src': [
		"'self'",
		'http://localhost:*',
		'http://127.0.0.1:*',
		'https://api.flapjack.foo',
		'https://api.staging.flapjack.foo',
		'https://api.stripe.com'
	],
	'default-src': ["'self'"],
	'font-src': ["'self'"],
	'form-action': ["'self'"],
	'frame-ancestors': ["'none'"],
	'frame-src': ['https://*.js.stripe.com', 'https://js.stripe.com', 'https://hooks.stripe.com'],
	'img-src': ["'self'", 'https:'],
	'object-src': ["'none'"],
	'script-src': ["'self'", 'https://*.js.stripe.com', 'https://js.stripe.com'],
	// The installed SvelteKit dev server deliberately adds unsafe-inline for its injected styles;
	// production responses instead augment the configured self source with a nonce or hash.
	'style-src': ["'self'", "'unsafe-inline'"],
	'style-src-attr': ["'unsafe-inline'"]
};

const SVELTEKIT_DYNAMIC_CSP_SOURCE = /^'(?:nonce-[^']+|sha(?:256|384|512)-[^']+)'$/;

function normalizedDirectiveMap(policy: string): Record<string, string[]> {
	return Object.fromEntries(
		policy
			.split(';')
			.map((directive) => directive.trim())
			.filter(Boolean)
			.map((directive) => {
				const [name, ...sources] = directive.split(/\s+/);
				return [name, sources.filter((source) => !SVELTEKIT_DYNAMIC_CSP_SOURCE.test(source))];
			})
	);
}

function expectEnforcedPolicy(response: Response): void {
	const headers = response.headers();
	const enforcedPolicy = headers['content-security-policy'];
	expect(enforcedPolicy).toBeDefined();
	expect(headers['content-security-policy-report-only']).toBeUndefined();
	expect(normalizedDirectiveMap(enforcedPolicy ?? '')).toEqual(EXPECTED_ENFORCED_CSP_DIRECTIVES);
}

test('security headers enforced policy has zero violations on required documents', async ({
	page,
	cspAudit,
	createFreshSignupIdentity,
	arrangeFreshSignupToDashboard
}) => {
	const signupResponse = await cspAudit.navigate('/signup');
	expectEnforcedPolicy(signupResponse);
	await expect(
		page.getByRole('heading', { name: 'Create your account', exact: true })
	).toBeVisible();

	const signup = createFreshSignupIdentity();
	const arrangeResult = await arrangeFreshSignupToDashboard(
		page,
		signup,
		cspAudit.flushPendingViolations
	);
	expect(
		arrangeResult.prerequisiteFailureMessage,
		'fresh signup is required for the authenticated CSP route audit'
	).toBeNull();

	const consoleResponse = await cspAudit.navigate('/console');
	expectEnforcedPolicy(consoleResponse);
	await expect(page.getByRole('heading', { name: 'Console', exact: true })).toBeVisible();

	const billingResponse = await cspAudit.navigate('/console/billing');
	expectEnforcedPolicy(billingResponse);
	await expect(page.getByRole('heading', { name: 'Billing', exact: true })).toBeVisible();

	expect(await cspAudit.result()).toEqual({
		violations: [],
		routeDenominators: {
			'/signup': 1,
			'/console': 1,
			'/console/billing': 1
		}
	});
});
