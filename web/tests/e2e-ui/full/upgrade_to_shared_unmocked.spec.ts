import { test, expect } from '../../fixtures/fixtures';
import {
	loginWithFixtureCredentials,
	gotoBillingPageWithSessionRecovery
} from '../../fixtures/billing_session_recovery';

// Drives the real `?/upgradeToShared` server action through Stripe test mode.
// Starts unauthenticated so `/login` always renders for the arranged fixture user.
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Upgrade-to-shared end-to-end (unmocked Stripe)', () => {
	test('downgraded free customer with default card upgrades to Paid via real Stripe @p0_coverage', async ({
		page,
		arrangeBillingPortalCustomer,
		setBillingPlanForCustomer,
		loginAs
	}) => {
		test.setTimeout(180_000);
		const arrangedCustomer = await arrangeBillingPortalCustomer();

		if (arrangedCustomer.stripeCustomerId.startsWith('cus_local_')) {
			test.skip(
				true,
				'Local Stripe mode does not exercise the real upgradeToShared path; unmocked upgrade proof requires Stripe test-mode credentials.'
			);
		}

		// arrangeBillingPortalCustomer always upgrades the customer to 'shared' so
		// it can attach payment methods. Move it back to 'free' so the upgrade CTA
		// renders for the unmocked drive.
		await setBillingPlanForCustomer(arrangedCustomer.customerId, 'free');

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

		// Baseline: customer is on Free with a default card attached, so the upgrade
		// CTA must render and the plan label must read "Free".
		await expect(page.getByTestId('current-plan-label')).toContainText('Free');
		const upgradeButton = page.getByTestId('upgrade-to-shared-button');
		await expect(upgradeButton).toBeVisible();

		// Drive the real `?/upgradeToShared` form action.
		const upgradeResponse = page.waitForResponse(
			(response) =>
				response.request().method() === 'POST' &&
				response.url().includes('/console/billing?/upgradeToShared') &&
				response.ok(),
			{ timeout: 60_000 }
		);
		await upgradeButton.click();
		await upgradeResponse;

		// End-effect: success banner, plan label flipped to Paid, CTA gone.
		const successBanner = page.getByTestId('upgrade-success-banner');
		await expect(successBanner).toBeVisible({ timeout: 30_000 });
		await expect(successBanner).toContainText("You're on Paid");
		await expect(successBanner).toContainText(/\$\d+\.\d{2}/);
		await expect(page.getByRole('heading', { name: 'Paid plan active' })).toBeVisible();
		await expect(page.getByTestId('current-plan-label')).toContainText('Paid');
		await expect(page.getByTestId('upgrade-to-shared-button')).toHaveCount(0);
	});
});
