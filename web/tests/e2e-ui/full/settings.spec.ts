/**
 * Full — Settings
 *
 * Verifies the complete account settings surface:
 *   - Load-and-verify: settings page renders profile with current email
 *   - Update display name through the UI form
 *   - Change password (wrong current password shows error)
 *   - Change password (new passwords mismatch shows error)
 *   - Password change lifecycle: change → logout → re-authenticate with new password
 *   - Self-service account deletion for a disposable local user
 */

import { test, expect } from '../../fixtures/fixtures';

test.describe('Settings page', () => {
	test('load-and-verify: renders profile section with email', async ({ page }) => {
		// Act: navigate to settings
		await page.goto('/dashboard/settings');

		// Assert: page-specific heading visible
		await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();

		// Assert: profile section visible with email shown
		await expect(page.getByRole('heading', { name: 'Profile' })).toBeVisible();
		await expect(page.getByLabel('Name')).toBeVisible();

		// Email is displayed as read-only text (not an input)
		await expect(page.getByText(process.env.E2E_USER_EMAIL ?? '')).toBeVisible();
	});

	test('update profile name shows success message', async ({ page }) => {
		await page.goto('/dashboard/settings');

		const newName = `E2E Test User ${Date.now()}`;

		// Act: update name and save
		await page.getByLabel('Name').fill(newName);
		await page.getByRole('button', { name: 'Save profile' }).click();

		// Assert: success message appears
		await expect(page.getByRole('status')).toBeVisible({ timeout: 5_000 });
		await expect(page.getByText('Profile updated successfully')).toBeVisible();
	});

	test('change password section is visible', async ({ page }) => {
		await page.goto('/dashboard/settings');

		await expect(page.getByRole('heading', { name: 'Change Password' })).toBeVisible();
		await expect(page.getByLabel('Current password')).toBeVisible();
		await expect(page.getByLabel('New password', { exact: true })).toBeVisible();
		await expect(page.getByLabel('Confirm new password')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Change password' })).toBeVisible();
	});

	test('wrong current password shows error', async ({ page }) => {
		await page.goto('/dashboard/settings');
		await expect(page.getByRole('heading', { name: 'Change Password' })).toBeVisible();

		// Act: submit with wrong current password
		await page.getByLabel('Current password').fill('definitely-wrong-password-999');
		await page.getByLabel('New password', { exact: true }).fill('NewValidPass1!');
		await page.getByLabel('Confirm new password').fill('NewValidPass1!');
		await page.getByRole('button', { name: 'Change password' }).click();

		// Assert: error shown
		await expect(page.getByRole('alert')).toBeVisible({ timeout: 5_000 });
	});

	test('mismatched new passwords shows error', async ({ page }) => {
		await page.goto('/dashboard/settings');
		await expect(page.getByRole('heading', { name: 'Change Password' })).toBeVisible();

		await page.getByLabel('Current password').fill(process.env.E2E_USER_PASSWORD ?? '');
		await page.getByLabel('New password', { exact: true }).fill('NewValidPass1!');
		await page.getByLabel('Confirm new password').fill('DifferentPass2@');
		await page.getByRole('button', { name: 'Change password' }).click();

		await expect(page.getByRole('alert')).toBeVisible({ timeout: 5_000 });
	});
});

test.describe('Settings password change lifecycle', () => {
	// Start unauthenticated — this block creates and uses a disposable user
	// instead of the shared setup:user auth state.
	test.use({ storageState: { cookies: [], origins: [] } });

	test('change password, log out, re-authenticate with new password', async ({
		page,
		createUser
	}) => {
		const email = `settings-reauth-${Date.now()}@e2e.griddle.test`;
		const oldPassword = 'OldPassword123!';
		const newPassword = 'NewPassword456!';

		// Arrange: create a disposable user via API (auto-cleaned up by fixture)
		await createUser(email, oldPassword, 'Settings Re-Auth Test');

		// Step 1: Log in through the UI
		await page.goto('/login');
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password').fill(oldPassword);
		await page.getByRole('button', { name: 'Log In' }).click();
		await expect(page).toHaveURL(/\/dashboard/, { timeout: 10_000 });

		// Step 2: Navigate to settings and change password
		await page.goto('/dashboard/settings');
		await expect(page.getByRole('heading', { name: 'Change Password' })).toBeVisible();

		await page.getByLabel('Current password').fill(oldPassword);
		await page.getByLabel('New password', { exact: true }).fill(newPassword);
		await page.getByLabel('Confirm new password').fill(newPassword);
		await page.getByRole('button', { name: 'Change password' }).click();

		// Assert: password change success message
		await expect(page.getByText('Password changed successfully')).toBeVisible({
			timeout: 5_000
		});

		// Step 3: Log out
		await page.getByRole('button', { name: 'Logout' }).click();
		await expect(page).toHaveURL(/\/login/, { timeout: 10_000 });

		// Step 4: Prove old password fails
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password').fill(oldPassword);
		await page.getByRole('button', { name: 'Log In' }).click();
		await expect(page.getByRole('alert')).toBeVisible({ timeout: 5_000 });
		await expect(page).toHaveURL(/\/login/);

		// Step 5: Prove new password succeeds (fresh navigation to clear form state)
		await page.goto('/login');
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password').fill(newPassword);
		await page.getByRole('button', { name: 'Log In' }).click();
		await expect(page).toHaveURL(/\/dashboard/, { timeout: 10_000 });
	});
});

test.describe('Settings delete-account flow', () => {
	test.use({ storageState: { cookies: [], origins: [] } });

	test('delete-account danger zone deletes a throwaway account and redirects to /login', async ({
		page
	}) => {
		const timestamp = Date.now();
		const throwawayEmail = `delete-settings-${timestamp}@e2e.griddle.test`;
		const throwawayPassword = 'DeleteMe123!';

		await page.goto('/signup');
		await page.getByLabel('Name').fill(`Delete Settings ${timestamp}`);
		await page.getByLabel('Email').fill(throwawayEmail);
		await page.getByLabel('Password', { exact: true }).fill(throwawayPassword);
		await page.getByLabel('Confirm Password').fill(throwawayPassword);
		await page.getByRole('button', { name: 'Sign Up' }).click();
		await expect(page).toHaveURL(/\/dashboard/, { timeout: 15_000 });

		await page.goto('/dashboard/settings');
		await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
		await expect(page.getByTestId('delete-account-danger-zone')).toBeVisible();
		await expect(page.getByRole('heading', { name: 'Delete Account' })).toBeVisible();

		await page.getByTestId('delete-account-open').click();
		await page.getByTestId('delete-account-password').fill(throwawayPassword);
		await page.getByTestId('delete-account-confirm').check();
		await page.getByTestId('delete-account-submit').click();

		await expect(page).toHaveURL(/\/login/, { timeout: 10_000 });
		await expect(page.getByRole('heading', { name: 'Log in to Flapjack Cloud' })).toBeVisible();
	});
});
