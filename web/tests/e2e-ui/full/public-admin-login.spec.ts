/**
 * Full public — Admin login
 *
 * Verifies unauthenticated admin login behavior from a blank browser state.
 */

import { expect, test } from '../../fixtures/fixtures';

test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Admin login page', () => {
	test('admin login page renders', async ({ page }) => {
		await page.goto('/admin/login');

		await expect(page.getByRole('heading', { name: 'Admin Login' })).toBeVisible();
		await expect(page.getByLabel('Admin Key')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Log In' })).toBeVisible();
	});

	test('admin login password toggle reveals admin key in place', async ({ page }) => {
		await page.goto('/admin/login');

		const adminKey = page.getByLabel('Admin Key');
		await adminKey.fill('wrong-key-123');
		await expect(adminKey).toHaveAttribute('type', 'password');
		await page.getByRole('button', { name: 'Show admin key' }).click();
		await expect(adminKey).toHaveAttribute('type', 'text');
		await expect(adminKey).toHaveValue('wrong-key-123');
		await expect(page.getByRole('button', { name: 'Hide admin key' })).toHaveAttribute(
			'aria-pressed',
			'true'
		);
	});

	test('wrong admin key shows error', async ({ page }) => {
		await page.goto('/admin/login');

		await page.getByLabel('Admin Key').fill('wrong-key-123');
		await page.getByRole('button', { name: 'Log In' }).click();

		await expect(page.getByRole('alert')).toBeVisible({ timeout: 5_000 });
		await expect(page).toHaveURL(/\/admin\/login/);
	});

	test('unauthenticated visit to /admin/fleet redirects to /admin/login', async ({ page }) => {
		await page.goto('/admin/fleet');

		await expect(page).toHaveURL(/\/admin\/login/);
	});
});
