/**
 * Smoke — Dashboard
 *
 * Critical path: the main dashboard page loads and renders its key sections.
 */

import { test, expect } from '../../fixtures/fixtures';

test('dashboard renders core sections', async ({ page }) => {
	await page.goto('/dashboard');

	await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();

	// Indexes card is always visible (even when empty)
	await expect(page.getByTestId('indexes-card')).toBeVisible();
	await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();
});

test('sidebar navigation links are present', async ({ page }) => {
	await page.goto('/dashboard');

	await expect(page.getByRole('link', { name: 'Indexes', exact: true })).toBeVisible();
	await expect(page.getByRole('link', { name: 'Billing', exact: true })).toBeVisible();
	await expect(page.getByRole('link', { name: 'API Keys' })).toBeVisible();
	await expect(page.getByRole('link', { name: 'Settings' })).toBeVisible();
});

test('plan badge is visible in the header', async ({ page }) => {
	await page.goto('/dashboard');

	const badge = page.getByTestId('plan-badge');
	await expect(badge).toBeVisible();
	await expect(badge).toHaveText(/(?:Free|Shared) Plan/);
});
