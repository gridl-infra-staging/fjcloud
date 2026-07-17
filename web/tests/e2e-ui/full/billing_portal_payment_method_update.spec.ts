import { test, expect } from '../../fixtures/fixtures';
import {
	isRemoteTargetMode,
	setAuthCookieForToken
} from '../../fixtures/fresh_signup_remote_bootstrap';
import type { FrameLocator } from '@playwright/test';

// This flow validates auth+billing lifecycle for a newly arranged customer.
// Start from an unauthenticated browser context so `/login` always renders.
test.use({ storageState: { cookies: [], origins: [] } });

const TRANSIENT_RATE_LIMIT_PATTERN = /too many requests/i;
const SESSION_EXPIRED_REASON = 'session_expired';

function isSessionExpiredUrl(urlString: string): boolean {
	const currentUrl = new URL(urlString);
	return (
		currentUrl.pathname === '/login' &&
		currentUrl.searchParams.get('reason') === SESSION_EXPIRED_REASON
	);
}

function sessionRecoveryFailure(detail: string): Error {
	return new Error(`Session-expired recovery failed for /console/billing: ${detail}`);
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
			await expect(page).toHaveURL(/\/console/, { timeout: 20_000 });
			return;
		} catch (error) {
			const loginAlert = page.getByRole('alert');
			const alertText = (await loginAlert.textContent().catch(() => null))?.trim() ?? '';
			if (TRANSIENT_RATE_LIMIT_PATTERN.test(alertText)) {
				throw new Error('Billing-portal login was transiently rate-limited; retrying');
			}
			// This suite validates billing payment-method behavior, not UI login
			// copy. Recover through fixture login token whenever browser login
			// doesn't land on /console.
			const token = await loginAs(email, password);
			await setAuthCookieForToken(page, token);
			await page.goto('/console');
			await expect(page).toHaveURL(/\/console/, { timeout: 20_000 });
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
	await page.goto('/console/billing');
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
	await page.goto('/console/billing');
	if (isSessionExpiredUrl(page.url())) {
		throw sessionRecoveryFailure(
			'navigation remained on /login?reason=session_expired after auth-cookie replay'
		);
	}
}

async function selectStripeCardCountry(stripeFrame: FrameLocator): Promise<void> {
	const country = stripeFrame.getByRole('combobox', { name: /^Country$/i });
	await expect(country).toBeVisible({ timeout: 30_000 });
	await country.selectOption('US');
	await expect(country).toHaveValue('US');
}

async function fillStripePostalCodeWhenPresent(stripeFrame: FrameLocator): Promise<void> {
	const postalCodeByLabel = stripeFrame.getByRole('textbox', { name: /ZIP|Postal code/i });
	if ((await postalCodeByLabel.count()) > 0) {
		await postalCodeByLabel.fill('10001');
		await expect(postalCodeByLabel).toHaveValue('10001');
		return;
	}

	const postalCodeByPlaceholder = stripeFrame.getByPlaceholder('12345');
	if ((await postalCodeByPlaceholder.count()) > 0) {
		await postalCodeByPlaceholder.fill('10001');
		await expect(postalCodeByPlaceholder).toHaveValue('10001');
	}
}

async function selectStripeCardMethodWhenPresent(stripeFrame: FrameLocator): Promise<void> {
	// The setup SetupIntent is constrained to card-only server-side
	// (payment_method_types=["card"] in infra/api/src/stripe/live.rs). With a single
	// payment method, Stripe renders the card form DIRECTLY and shows no
	// payment-method selector, so there is no clickable "Card" tab. Click one only
	// if it is present — i.e. if the intent is ever broadened to multiple methods,
	// the selector reappears and this still drives it. The card-number field wait
	// at the call site is the real form-readiness gate either way. (Historically
	// this click was unconditional, which broke the lane the moment the card-only
	// constraint landed and was never re-verified.)
	const cardMethodButton = stripeFrame.getByRole('button', { name: /^Card$/i });
	if ((await cardMethodButton.count()) > 0) {
		await cardMethodButton.click();
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
				request.url().includes('/console/billing?/setDefaultPaymentMethod'),
			{ timeout: 30_000 }
		);
		const setDefaultActionResponse = page.waitForResponse(
			(response) =>
				response.request().method() === 'POST' &&
				response.url().includes('/console/billing?/setDefaultPaymentMethod') &&
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

		await expect(page).toHaveURL(/\/console\/billing/);
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

	test('saves a new payment method via the Stripe Payment Element on /console/billing/setup @p0_coverage', async ({
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

		if (arrangedCustomer.stripeCustomerId.startsWith('cus_local_')) {
			test.skip(
				true,
				'Local Stripe mode does not expose the hosted Payment Element; initial-save proof requires Stripe test-mode credentials.'
			);
		}

		// Baseline: arrangeBillingPortalCustomer attaches one Visa (pm_card_visa,
		// last4=4242) as the default PM.
		const visaRowLocator = page.getByText('Visa ending in 4242');
		await expect(visaRowLocator).toHaveCount(1);

		await page.goto('/console/billing/setup');
		await expect(page.getByRole('heading', { name: 'Add Payment Method' })).toBeVisible();
		await expect(page.getByTestId('payment-element')).toBeVisible();

		// The Stripe Payment Element mounts a Stripe-hosted iframe inside the
		// `payment-element` testid container. The iframe `name` is dynamic
		// (`__privateStripeFrame<n>`), so target it by prefix from inside the host.
		const stripeFrame = page
			.getByTestId('payment-element')
			.frameLocator('iframe[name^="__privateStripeFrame"]');

		await selectStripeCardMethodWhenPresent(stripeFrame);

		const cardNumberField = stripeFrame.getByRole('textbox', { name: /Card number/i });
		await expect(cardNumberField).toBeVisible({ timeout: 30_000 });
		await cardNumberField.fill('4242424242424242');

		await stripeFrame.getByRole('textbox', { name: /Expiration/i }).fill('1230');
		await stripeFrame.getByRole('textbox', { name: /CVC|Security code/i }).fill('123');

		await selectStripeCardCountry(stripeFrame);

		// Postal/ZIP collection depends on Stripe Element config + customer
		// billing-address state. Fill only when the field renders.
		await fillStripePostalCodeWhenPresent(stripeFrame);

		await page.getByRole('button', { name: 'Save payment method' }).click();
		await page.waitForURL(/\/console\/billing(?:\?|$)/, { timeout: 60_000 });

		// End-effect: the setup flow returns to the billing page and preserves the
		// existing default card. Stripe may or may not de-duplicate the identical
		// test card fingerprint, so accept count 1 (de-duplicated) or 2 (both kept).
		await expect(page.getByRole('heading', { name: 'Payment methods' })).toBeVisible();
		await expect(visaRowLocator.first()).toBeVisible({ timeout: 30_000 });

		// Stripe-API end-effect: the customer's default PM should still be the
		// fixture-attached default (Stripe does not auto-promote SetupIntent PMs).
		const defaultPaymentMethodId = await waitForStripeDefaultPaymentMethod(
			arrangedCustomer.stripeCustomerId,
			arrangedCustomer.defaultPaymentMethodId
		);
		expect(defaultPaymentMethodId).toBe(arrangedCustomer.defaultPaymentMethodId);
	});
});
