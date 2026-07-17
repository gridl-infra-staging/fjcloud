/**
 * Full stack — Account deletion
 *
 * Exercises self-service deletion against disposable accounts from a blank browser state.
 */

import { test, expect } from '../../fixtures/fixtures';

const STAGING_CUSTOMER_LOOKUP_UNAVAILABLE_PATTERN =
	/ssm_exec_staging\.sh (failed to spawn|exited \d+)/i;

function isStagingCustomerLookupUnavailable(error: unknown): boolean {
	if (!(error instanceof Error)) {
		return false;
	}
	return STAGING_CUSTOMER_LOOKUP_UNAVAILABLE_PATTERN.test(error.message);
}

test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Account delete-account flow', () => {
	test('delete-account danger zone deletes a throwaway account and redirects to /login', async ({
		page,
		createFreshSignupIdentity,
		arrangeFreshSignupToDashboard,
		findCustomerStatusViaStagingSsm
	}) => {
		const signup = createFreshSignupIdentity();
		const arrangeResult = await arrangeFreshSignupToDashboard(page, signup);
		if (arrangeResult.prerequisiteFailureMessage) {
			test.skip(
				true,
				`account delete lifecycle prerequisite unavailable in local env: ${arrangeResult.prerequisiteFailureMessage}`
			);
			return;
		}
		const throwawayPassword = signup.password;

		await page.goto('/console/account');
		await expect(page.getByRole('heading', { name: 'Account', exact: true })).toBeVisible();
		await expect(page.getByTestId('delete-account-danger-zone')).toBeVisible();
		await expect(page.getByRole('heading', { name: 'Delete Account' })).toBeVisible();

		await page.getByTestId('delete-account-open').click();
		await page.getByTestId('delete-account-password').fill(throwawayPassword);
		await page.getByTestId('delete-account-confirm').check();
		await page.getByTestId('delete-account-submit').click();

		await expect(page).toHaveURL(/\/login/, { timeout: 10_000 });
		await expect(page.getByRole('heading', { name: 'Log in to Flapjack Cloud' })).toBeVisible();

		let customerStatus: Awaited<ReturnType<typeof findCustomerStatusViaStagingSsm>>;
		try {
			customerStatus = await findCustomerStatusViaStagingSsm(signup.email);
		} catch (error) {
			if (isStagingCustomerLookupUnavailable(error)) {
				const reason = error instanceof Error ? error.message : String(error);
				test.skip(
					true,
					`account delete lifecycle staging proof unavailable in local env: ${reason}`
				);
				return;
			}
			throw error;
		}
		expect(customerStatus.stagingStatus).toBe('deleted');
		expect(customerStatus.stagingCustomerId).toMatch(/\S+/);
	});

	test('delete-account password toggle reveals field in place', async ({
		page,
		createFreshSignupIdentity,
		arrangeFreshSignupToDashboard
	}) => {
		const signup = createFreshSignupIdentity();
		const arrangeResult = await arrangeFreshSignupToDashboard(page, signup);
		// eslint-disable-next-line playwright/no-conditional-in-test -- disposable-account auth is an environment prerequisite for this destructive-flow surface
		if (arrangeResult.prerequisiteFailureMessage) {
			// eslint-disable-next-line playwright/no-skipped-test -- local signup prerequisites can be unavailable outside full-stack runs
			test.skip(
				true,
				`account delete password toggle prerequisite unavailable in local env: ${arrangeResult.prerequisiteFailureMessage}`
			);
			return;
		}

		await page.goto('/console/account');
		await page.getByTestId('delete-account-open').click();
		const dangerZone = page.getByTestId('delete-account-danger-zone');
		const passwordInput = page.getByTestId('delete-account-password');

		await passwordInput.fill(signup.password);
		await expect(passwordInput).toHaveAttribute('type', 'password');
		await dangerZone.getByRole('button', { name: 'Show password' }).click();
		await expect(passwordInput).toHaveAttribute('type', 'text');
		await expect(passwordInput).toHaveValue(signup.password);
		await expect(page.getByTestId('delete-account-submit')).toBeDisabled();
	});
});
