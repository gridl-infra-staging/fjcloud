/**
 * Full stack — Account password lifecycle
 *
 * Exercises disposable account password changes from a blank browser state.
 */

import { test, expect } from '../../fixtures/fixtures';

test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Account password change lifecycle', () => {
	test('change password, log out, re-authenticate with new password', async ({
		page,
		createUser,
		isFreshSignupArrangePrerequisiteFailure
	}) => {
		const email = `account-reauth-${Date.now()}@e2e.griddle.test`;
		const oldPassword = 'OldPassword123!';
		const newPassword = 'NewPassword456!';

		try {
			await createUser(email, oldPassword, 'Account Re-Auth Test');
		} catch (error) {
			const failureMessage = error instanceof Error ? error.message : String(error);
			if (isFreshSignupArrangePrerequisiteFailure(failureMessage)) {
				test.skip(
					true,
					`account password lifecycle prerequisite unavailable in local env: ${failureMessage}`
				);
				return;
			}
			throw error;
		}

		await page.goto('/login');
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password').fill(oldPassword);
		await page.getByRole('button', { name: 'Log In' }).click();
		await expect(page).toHaveURL(/\/console/, { timeout: 10_000 });

		await page.goto('/console/account');
		await expect(page.getByRole('heading', { name: 'Change Password' })).toBeVisible();

		await page.getByLabel('Current password').fill(oldPassword);
		await page.getByLabel('New password', { exact: true }).fill(newPassword);
		await page.getByLabel('Confirm new password').fill(newPassword);
		await page.getByRole('button', { name: 'Change password' }).click();

		await expect(
			page.getByTestId('shared-toast-mount').getByText('Password changed successfully')
		).toBeVisible({
			timeout: 5_000
		});
		await expect(
			page.getByTestId('account-page').getByRole('status').filter({
				hasText: 'Password changed successfully'
			})
		).toHaveCount(0);
		await expect(
			page.getByTestId('account-export-status').filter({
				hasText: 'Password changed successfully'
			})
		).toHaveCount(0);

		await page.getByRole('button', { name: 'Logout' }).click();
		await expect(page).toHaveURL(/\/login/, { timeout: 10_000 });

		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password').fill(oldPassword);
		await page.getByRole('button', { name: 'Log In' }).click();
		await expect(page.getByRole('alert')).toBeVisible({ timeout: 5_000 });
		await expect(page).toHaveURL(/\/login/);

		await page.goto('/login');
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password').fill(newPassword);
		await page.getByRole('button', { name: 'Log In' }).click();
		await expect(page).toHaveURL(/\/console/, { timeout: 10_000 });
	});
});
