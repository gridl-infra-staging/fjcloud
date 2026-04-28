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

		const navigatedToPortal = await Promise.all([
			page
				.waitForURL(/billing\.stripe\.com|local-billing-portal/, { timeout: 30_000 })
				.then(() => true)
				.catch(() => false),
			page.getByRole('button', { name: 'Manage billing' }).click()
		]).then(([result]) => result);

		expect(
			navigatedToPortal,
			'Manage billing did not redirect to Stripe Customer Portal. Ensure Stripe portal credentials are configured.'
		).toBe(true);

		const portalUrl = page.url();
		expect(
			/billing\.stripe\.com/.test(portalUrl),
			`Portal cancellation flow requires billing.stripe.com (got: ${portalUrl})`
		).toBe(true);

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
