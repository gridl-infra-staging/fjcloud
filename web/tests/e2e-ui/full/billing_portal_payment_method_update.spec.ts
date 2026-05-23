import { test, expect } from '../../fixtures/fixtures';
import {
	isRemoteTargetMode,
	setAuthCookieForToken
} from '../../fixtures/fresh_signup_remote_bootstrap';

const TRANSIENT_RATE_LIMIT_PATTERN = /too many requests/i;
const SESSION_EXPIRED_REASON = 'session_expired';

function isSessionExpiredUrl(urlString: string): boolean {
	const currentUrl = new URL(urlString);
	return currentUrl.pathname === '/login' && currentUrl.searchParams.get('reason') === SESSION_EXPIRED_REASON;
}

function sessionRecoveryFailure(detail: string): Error {
	return new Error(`Session-expired recovery failed for /dashboard/billing: ${detail}`);
}

async function loginWithFixtureCredentials(
	page: import('@playwright/test').Page,
	email: string,
	password: string,
	loginAs: (email: string, password: string) => Promise<string>
): Promise<void> {
	await expect(async () => {
		await page.goto('/login');
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password').fill(password);
		await page.getByRole('button', { name: 'Log In' }).click();

		try {
			await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 });
			return;
		} catch (error) {
			const loginAlert = page.getByRole('alert');
			const alertText = (await loginAlert.textContent().catch(() => null))?.trim() ?? '';
			if (TRANSIENT_RATE_LIMIT_PATTERN.test(alertText)) {
				throw new Error('Billing-portal login was transiently rate-limited; retrying');
			}
			if (!isRemoteTargetMode()) {
				throw error;
			}

			const token = await loginAs(email, password);
			await setAuthCookieForToken(page, token);
			await page.goto('/dashboard');
			await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 });
		}
	}).toPass({
		intervals: [1_000, 2_000, 3_000, 4_000, 5_000],
		timeout: 60_000
	});
}

async function gotoBillingPageWithSessionRecovery(
	page: import('@playwright/test').Page,
	email: string,
	password: string,
	loginAs: (email: string, password: string) => Promise<string>
): Promise<void> {
	await page.goto('/dashboard/billing');
	if (!isSessionExpiredUrl(page.url())) {
		return;
	}
	if (!isRemoteTargetMode()) {
		throw sessionRecoveryFailure(
			'initial navigation hit /login?reason=session_expired but remote recovery is unavailable'
		);
	}

	const token = await loginAs(email, password);
	await setAuthCookieForToken(page, token);
	await page.goto('/dashboard/billing');
	if (isSessionExpiredUrl(page.url())) {
		throw sessionRecoveryFailure(
			'navigation remained on /login?reason=session_expired after auth-cookie replay'
		);
	}
}

test.describe('Billing in-app payment-method updates', () => {
	test('updates default payment method in-app and keeps billing page stable', async ({
		page,
		arrangeBillingPortalCustomer,
		waitForStripeDefaultPaymentMethod,
		loginAs
	}) => {
		test.setTimeout(180_000);
		const arrangedCustomer = await arrangeBillingPortalCustomer();

		await loginWithFixtureCredentials(
			page,
			arrangedCustomer.email,
			arrangedCustomer.password,
			loginAs
		);
		await gotoBillingPageWithSessionRecovery(
			page,
			arrangedCustomer.email,
			arrangedCustomer.password,
			loginAs
		);
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
		const currentDefaultPaymentMethodId = await waitForStripeDefaultPaymentMethod(
			arrangedCustomer.stripeCustomerId,
			arrangedCustomer.expectedDefaultPaymentMethodId
		);
		expect(currentDefaultPaymentMethodId).toBe(arrangedCustomer.expectedDefaultPaymentMethodId);
	});
});
