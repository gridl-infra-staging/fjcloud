import type { Page, Response } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';
const BILLING_PATH_PREFIX = '/dashboard/billing';
const BASE_URL_PROTOCOL = new URL(BASE_URL).protocol;

async function setAuthCookieForToken(page: Page, token: string): Promise<void> {
	await page.context().addCookies([
		{
			name: AUTH_COOKIE,
			value: token,
			url: BASE_URL,
			httpOnly: true,
			secure: BASE_URL_PROTOCOL === 'https:',
			sameSite: 'Lax'
		}
	]);
}

function assertBillingReturnPath(urlCandidate: string): void {
	const resolved = new URL(urlCandidate, BASE_URL);
	expect(
		resolved.pathname.startsWith(BILLING_PATH_PREFIX),
		`Billing portal return path must resolve back to ${BILLING_PATH_PREFIX} (got: ${resolved.toString()})`
	).toBe(true);
}

function readManageBillingRedirectLocation(response: Response | null): string | null {
	if (response === null) {
		return null;
	}
	return response.headers()['location'] ?? null;
}

test.describe('Billing portal payment-method update handoff', () => {
	test('manage billing hands off to portal URL and resolves return path to billing', async ({
		page,
		arrangeBillingPortalCustomer
	}) => {
		test.setTimeout(180_000);
		const arrangedCustomer = await arrangeBillingPortalCustomer();

		await setAuthCookieForToken(page, arrangedCustomer.token);
		await page.goto('/dashboard/billing');
		const manageBillingButton = page.getByRole('button', { name: 'Manage billing' });
		await expect(manageBillingButton).toBeVisible();

		const portalUrlPattern = /billing\.stripe\.com|\/local-billing-portal\//;
		const manageBillingActionPath = '/dashboard/billing?/manageBilling';
		const manageBillingActionResponsePromise = page
			.waitForResponse(
				(response) =>
					response.request().method() === 'POST' &&
					response.url().includes(manageBillingActionPath),
				{ timeout: 30_000 }
			)
			.catch(() => null);

		const [portalTransitionResult, manageBillingActionResponse] = await Promise.all([
			Promise.race([
				page
					.waitForURL(portalUrlPattern, { timeout: 30_000 })
					.then(() => ({ type: 'url' as const, url: page.url() })),
				// The waitForEvent promise IS awaited through Promise.race(...) and Promise.all(...).
				// eslint-disable-next-line playwright/missing-playwright-await -- awaited via outer Promise.race / Promise.all
				page
					.waitForEvent('requestfailed', {
						timeout: 30_000,
						predicate: (request) => portalUrlPattern.test(request.url())
					})
					.then((request) => ({ type: 'requestfailed' as const, url: request.url() }))
			]).catch(() => null),
			manageBillingActionResponsePromise,
			manageBillingButton.click()
		]);

		const actionLocation = readManageBillingRedirectLocation(manageBillingActionResponse);
		const portalTransition =
			portalTransitionResult ??
			(actionLocation !== null && portalUrlPattern.test(actionLocation)
				? { type: 'action-response' as const, url: actionLocation }
				: null);

		expect(
			portalTransition !== null,
			`Manage billing did not redirect to a recognized billing portal URL (url=${page.url()})`
		).toBe(true);
		expect(portalTransition).not.toBeNull();

		const portalUrl = portalTransition!.url;
		expect(
			portalUrlPattern.test(portalUrl),
			`Portal redirect must match Stripe-hosted or local mock contract (got: ${portalUrl})`
		).toBe(true);

		if (portalTransition!.type === 'requestfailed') {
			expect(
				/\/local-billing-portal\//.test(portalUrl),
				`Only local Stripe portal redirects may be unreachable in local-dev lanes (got: ${portalUrl})`
			).toBe(true);
		}

		if (actionLocation !== null) {
			const actionLocationUrl = new URL(actionLocation, BASE_URL);
			const actionReturnUrl = actionLocationUrl.searchParams.get('return_url');
			if (actionReturnUrl !== null) {
				assertBillingReturnPath(actionReturnUrl);
			}
		}

		if (/\/local-billing-portal\//.test(portalUrl)) {
			expect(
				/^http:\/\/localhost:3000\/local-billing-portal\/[^/]+$/.test(portalUrl),
				`Local Stripe portal redirect did not match expected contract URL shape (got: ${portalUrl})`
			).toBe(true);
			test.skip(
				true,
				'Local Stripe mode validates portal handoff and return-url contract; hosted portal return navigation is not available in this lane.'
			);
		}

		let returnedToBilling = await page
			.waitForURL(/\/dashboard\/billing/, { timeout: 20_000 })
			.then(() => true)
			.catch(() => false);

		if (!returnedToBilling) {
			const returnToAppLink = page.getByRole('link', {
				name: /return|back to|billing|flapjack/i
			});
			expect(
				await returnToAppLink.count(),
				'Stripe portal did not expose a return-to-billing path'
			).toBeGreaterThan(0);
			await Promise.all([
				page.waitForURL(/\/dashboard\/billing/, { timeout: 30_000 }),
				returnToAppLink.first().click()
			]);
			returnedToBilling = true;
		}

		expect(returnedToBilling).toBe(true);
		await expect(page).toHaveURL(/\/dashboard\/billing/);
	});
});
