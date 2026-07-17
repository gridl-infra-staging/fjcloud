/**
 * Full — Account
 *
 * Verifies the complete account-management surface:
 *   - Load-and-verify: account page renders profile with current email
 *   - Update display name through the UI form
 *   - Change password (wrong current password shows error)
 *   - Change password (new passwords mismatch shows error)
 */

import { test, expect } from '../../fixtures/fixtures';
import { resolveRequiredFixtureUserCredentials } from '../../../playwright.config.contract';
import { TOAST_DURATION_MS } from '../../../src/lib/toast_contract';

const sharedFixtureUser = resolveRequiredFixtureUserCredentials(process.env);

test.describe('Account page', () => {
	test('load-and-verify: renders profile section with email', async ({ page }) => {
		// Act: navigate to account
		await page.goto('/console/account');

		// Assert: page-specific heading visible
		await expect(page.getByRole('heading', { name: 'Account', exact: true })).toBeVisible();

		// Assert: profile section visible with email shown
		await expect(page.getByRole('heading', { name: 'Profile' })).toBeVisible();
		await expect(page.getByLabel('Name')).toBeVisible();

		// Email is displayed as read-only text (not an input)
		await expect(page.getByText(sharedFixtureUser.email, { exact: true })).toBeVisible();
		await expect(
			page.getByText(
				'This deactivates your account and signs you out. Retained audit records may remain. Deleting the account does not cancel billing.',
				{ exact: true }
			)
		).toBeVisible();
	});

	test('update profile name shows success toast', async ({
		page,
		arrangeTrackedCustomerSession
	}) => {
		await arrangeTrackedCustomerSession(page, { emailPrefix: 'account-profile-save' });
		await page.goto('/console/account');

		const newName = `E2E Test User ${Date.now()}`;

		// Act: update name and save
		await page.getByLabel('Name').fill(newName);
		await page.getByRole('button', { name: 'Save profile' }).click();

		// Assert: success toast appears without reviving the old inline status owner
		const profileSavedToast = page
			.getByTestId('shared-toast-mount')
			.getByText('Profile updated successfully');
		await expect(profileSavedToast).toBeVisible({ timeout: 5_000 });
		await expect(
			page.getByTestId('account-page').getByRole('status').filter({
				hasText: 'Profile updated successfully'
			})
		).toHaveCount(0);
		await expect(
			page.getByTestId('account-export-status').filter({
				hasText: 'Profile updated successfully'
			})
		).toHaveCount(0);
		await page.mouse.move(0, 0);
		await expect(profileSavedToast).toBeHidden({ timeout: TOAST_DURATION_MS + 2_000 });
	});

	test('change password section is visible', async ({ page }) => {
		await page.goto('/console/account');

		await expect(page.getByRole('heading', { name: 'Change Password' })).toBeVisible();
		await expect(page.getByLabel('Current password')).toBeVisible();
		await expect(page.getByLabel('New password', { exact: true })).toBeVisible();
		await expect(page.getByLabel('Confirm new password')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Change password' })).toBeVisible();
	});

	test('change-password password toggle reveals fields in place', async ({ page }) => {
		await page.goto('/console/account');

		const currentPassword = page.getByLabel('Current password');
		const newPassword = page.getByLabel('New password', { exact: true });

		await currentPassword.fill('current-password-123');
		await expect(currentPassword).toHaveAttribute('type', 'password');
		await page.getByRole('button', { name: 'Show password' }).first().click();
		await expect(currentPassword).toHaveAttribute('type', 'text');
		await expect(currentPassword).toHaveValue('current-password-123');
		await expect(newPassword).toHaveAttribute('type', 'password');
	});

	test('wrong current password shows error', async ({ page }) => {
		await page.goto('/console/account');
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
		await page.goto('/console/account');
		await expect(page.getByRole('heading', { name: 'Change Password' })).toBeVisible();

		await page.getByLabel('Current password').fill(sharedFixtureUser.password);
		await page.getByLabel('New password', { exact: true }).fill('NewValidPass1!');
		await page.getByLabel('Confirm new password').fill('DifferentPass2@');
		await page.getByRole('button', { name: 'Change password' }).click();

		await expect(page.getByRole('alert')).toBeVisible({ timeout: 5_000 });
	});

	test('account export renders download-ready state after form submission @p0_coverage', async ({
		page
	}) => {
		await page.goto('/console/account');
		await expect(page.getByRole('heading', { name: 'Account', exact: true })).toBeVisible();

		await page.getByRole('button', { name: 'Export account data' }).click();

		const exportStatus = page.getByTestId('account-export-status');
		await expect(exportStatus).toBeVisible({ timeout: 10_000 });
		await expect(exportStatus).toContainText('Account export ready');
		await expect(exportStatus).toContainText('Your export is ready to download.');
		await expect(
			exportStatus.getByRole('button', { name: 'Download account export' })
		).toBeVisible();
	});
});
