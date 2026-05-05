import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';
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

test.describe('Billing in-app payment-method updates', () => {
	test('updates default payment method in-app and keeps billing page stable', async ({
		page,
		arrangeBillingPortalCustomer
	}) => {
		test.setTimeout(180_000);
		const arrangedCustomer = await arrangeBillingPortalCustomer();

		await setAuthCookieForToken(page, arrangedCustomer.token);
		await page.goto('/dashboard/billing');
		await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
		await expect(page.getByRole('heading', { name: 'Payment methods' })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Manage billing' })).toHaveCount(0);

		if (arrangedCustomer.stripeCustomerId.startsWith('cus_local_')) {
			test.skip(
				true,
				'Local Stripe mode does not expose Stripe-hosted payment-method fixtures; in-app default-switch proof requires Stripe test-mode customer state.'
			);
		}

		await expect(page.getByTestId('payment-element')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Save payment method' })).toBeVisible();

		const setDefaultActionRequest = page.waitForRequest(
			(request) =>
				request.method() === 'POST' &&
				request.url().includes('/dashboard/billing?/setDefaultPaymentMethod'),
			{ timeout: 30_000 }
		);
		const setDefaultActionResponse = page.waitForResponse(
			(response) =>
				response.request().method() === 'POST' &&
				response.url().includes('/dashboard/billing?/setDefaultPaymentMethod') &&
				response.ok(),
			{ timeout: 30_000 }
		);
		const targetDefaultForm = page.getByTestId(
			`set-default-form-${arrangedCustomer.nonDefaultPaymentMethodId}`
		);
		await expect(targetDefaultForm).toHaveCount(1);

		await Promise.all([
			setDefaultActionRequest,
			setDefaultActionResponse,
			targetDefaultForm.getByRole('button', { name: 'Set as default' }).click()
		]);

		// Server-owned backend contract coverage lives in billing.server.test.ts
		// because `/billing/*` calls are made by `+page.server.ts`, not by the browser.

		const actionRequest = await setDefaultActionRequest;
		const requestBody = actionRequest.postData() ?? '';
		expect(requestBody).toContain(
			`paymentMethodId=${encodeURIComponent(arrangedCustomer.nonDefaultPaymentMethodId)}`
		);

		await expect(page).toHaveURL(/\/dashboard\/billing/);
		await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
		await expect(page.getByRole('heading', { name: 'Payment methods' })).toBeVisible();
		await expect(page.getByTestId('payment-element')).toBeVisible();
		await expect(
			page.getByTestId(
				`set-default-payment-method-id-${arrangedCustomer.nonDefaultPaymentMethodId}`
			)
		).toHaveCount(0);
		await expect(page.getByText('Default', { exact: true })).toHaveCount(1);
	});
});
