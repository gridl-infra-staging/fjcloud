import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';

async function setAuthCookieForToken(page: Page, token: string): Promise<void> {
	await page.context().addCookies([
		{
			name: AUTH_COOKIE,
			value: token,
			url: BASE_URL,
			httpOnly: true,
			sameSite: 'Lax'
		}
	]);
}

test.describe('Billing portal cancellation', () => {
	test('billing portal cancel returns to billing with server-owned cancellation banner', async ({
		page,
		arrangeBillingPortalCustomer
	}) => {
		test.setTimeout(180_000);
		const arrangedCustomer = await arrangeBillingPortalCustomer(false);

		await setAuthCookieForToken(page, arrangedCustomer.token);
		await page.goto('/dashboard/billing');
		await expect(page.getByRole('button', { name: 'Manage billing' })).toBeVisible();
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
		let portalTransition = await Promise.all([
			Promise.race([
				page
					.waitForURL(portalUrlPattern, { timeout: 30_000 })
					.then(() => ({ type: 'url' as const, url: page.url() })),
				page.waitForEvent('requestfailed', {
					timeout: 30_000,
					predicate: (request) => portalUrlPattern.test(request.url())
				}).then((request) => ({ type: 'requestfailed' as const, url: request.url() }))
			]).catch(() => null),
			manageBillingActionResponsePromise,
			page.getByRole('button', { name: 'Manage billing' }).click()
		]).then(([result, manageBillingActionResponse]) => {
			if (result !== null) {
				return result;
			}
			if (manageBillingActionResponse === null) {
				return null;
			}
			const locationHeader = manageBillingActionResponse.headers()['location'];
			if (locationHeader && portalUrlPattern.test(locationHeader)) {
				return { type: 'action-response' as const, url: locationHeader };
			}
			return null;
		});
		const currentUrlAfterClick = page.url();
		const portalActionAlert = page.getByRole('alert');
		const portalActionAlertText =
			(await portalActionAlert.count()) > 0
				? ((await portalActionAlert.first().textContent()) ?? '').trim()
				: '(no alert)';

		expect(
			portalTransition !== null,
			`Manage billing did not redirect to a recognized billing portal URL (url=${currentUrlAfterClick}, alert=${portalActionAlertText}).`
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
		if (/\/local-billing-portal\//.test(portalUrl)) {
			expect(
				/^http:\/\/localhost:3000\/local-billing-portal\/[^/]+$/.test(portalUrl),
				`Local Stripe portal redirect did not match expected contract URL shape (got: ${portalUrl})`
			).toBe(true);
			test.skip(
				true,
				'Local Stripe mode only contracts redirect URL ownership; cancellation UI flow requires Stripe-hosted portal lane.'
			);
		}

		const cancelPlanButton = page.getByRole('button', {
			name: /cancel|cancel plan|cancel subscription/i
		});
		expect(
			await cancelPlanButton.count(),
			'Stripe portal did not expose a cancel action in this environment'
		).toBeGreaterThan(0);
		await cancelPlanButton.first().click();

		const confirmCancellation = page.getByRole('button', {
			name: /confirm|yes, cancel|cancel subscription/i
		});
		if ((await confirmCancellation.count()) > 0) {
			await confirmCancellation.first().click();
		}

		let returnedToBilling = await page
			.waitForURL(/\/dashboard\/billing/, { timeout: 20_000 })
			.then(() => true)
			.catch(() => false);

		if (!returnedToBilling) {
			const returnToAppLink = page.getByRole('link', {
				name: /return|back to|flapjack/i
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

		await expect
			.poll(
				async () => {
					await page.goto('/dashboard/billing');
					const banner = page.getByTestId('subscription-cancelled-banner');
					if ((await banner.count()) === 0) {
						return '';
					}
					return (await banner.innerText()).trim();
				},
				{ timeout: 60_000 }
			)
			.toBe(`Subscription cancelled, ends ${arrangedCustomer.subscription.current_period_end}`);
	});
});
