/**
 * Smoke — Auth
 *
 * Critical path: a returning customer can log in and reach the dashboard.
 * Stored auth state is not used here so we always exercise the real login flow.
 */

import { test, expect } from '@playwright/test';

// This smoke test intentionally opts out of the pre-loaded storageState
// so it always verifies the live login path.
test.use({ storageState: { cookies: [], origins: [] } });

test('login with valid credentials reaches the dashboard', async ({ page }) => {
	const email = process.env.E2E_USER_EMAIL ?? '';
	const password = process.env.E2E_USER_PASSWORD ?? '';

	await page.goto('/login');

	await expect(page).toHaveTitle(/Flapjack Cloud/);
	await expect(page).not.toHaveTitle(/Griddle/);
	await expect(page.getByRole('heading', { name: 'Log in to Flapjack Cloud' })).toBeVisible();

	await page.getByLabel('Email').fill(email);
	await page.getByLabel('Password').fill(password);
	await page.getByRole('button', { name: 'Log in' }).click();

	await expect(page).toHaveURL(/\/dashboard/, { timeout: 10_000 });
	await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
});
