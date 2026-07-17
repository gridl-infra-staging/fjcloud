/**
 * Smoke — Console
 *
 * Critical path: the main console page loads and renders its key sections.
 */

import { test, expect } from '../../fixtures/fixtures';

test('console renders core sections', async ({ page }) => {
	await page.goto('/console');

	const shellHeader = page.getByTestId('dashboard-shell-header');
	await expect(shellHeader).toHaveClass(/(?:^|\s)bg-brand-cream(?:\s|$)/);
	await expect(shellHeader).toHaveClass(
		/^(?=.*(?:^|\s)border-flapjack-ink\/15(?:\s|$))(?=.*(?:^|\s)text-flapjack-ink(?:\s|$)).*$/
	);

	await expect(page.getByRole('heading', { name: 'Console' })).toBeVisible();

	// Indexes card is always visible (even when empty)
	await expect(page.getByTestId('indexes-card')).toBeVisible();
	await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();
});

test('sidebar navigation links are present', async ({ page }) => {
	await page.goto('/console');

	await expect(
		page.getByTestId('dashboard-nav-desktop').getByRole('link', { name: 'Console', exact: true })
	).toHaveClass(/(?:^|\s)bg-flapjack-mint(?:\s|$)/);
	await expect(page.getByRole('link', { name: 'Indexes', exact: true })).toBeVisible();
	await expect(page.getByRole('link', { name: 'Billing', exact: true })).toBeVisible();
	await expect(page.getByRole('link', { name: 'API Keys' })).toBeVisible();
	await expect(page.getByRole('link', { name: 'Account' })).toBeVisible();
});

test('plan badge is visible in the header', async ({ page }) => {
	await page.goto('/console');

	const badge = page.getByTestId('plan-badge');
	await expect(badge).toBeVisible();
	await expect(badge).toHaveText(/(?:Free|Paid) Plan/);
});

test('legacy /dashboard entry permanently lands on /console', async ({ page }) => {
	// Stage 6 deployment-verification probe: navigating to the legacy
	// /dashboard URL must arrive at the matching /console URL via the 308
	// redirect chain. URL assertion is deterministic across renders and
	// resilient to copy changes inside the console surface.
	await page.goto('/dashboard');
	await expect(page).toHaveURL(/\/console(?:\?.*)?$/);
});

test('legacy /dashboard deep-link entry preserves path on /console', async ({ page }) => {
	await page.goto('/dashboard/billing');
	await expect(page).toHaveURL(/\/console\/billing(?:\?.*)?$/);
});
