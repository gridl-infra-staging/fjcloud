/**
 * Smoke — Indexes
 *
 * Critical path: load-and-verify that a seeded index appears in the indexes
 * table, confirming the frontend→API→DB read path is healthy.
 */

import { test, expect } from '../../fixtures/fixtures';

test('seeded index appears in the indexes table', async ({ page, seedIndex }) => {
	const name = `smoke-idx-${Date.now()}`;

	// Arrange: seed via API (allowed ARRANGE shortcut)
	await seedIndex(name);

	// Act: navigate to indexes page
	await page.goto('/console/indexes');

	// Assert: page-specific heading visible (not nav text)
	await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();

	// Assert: seeded index name appears in the table body
	await expect(page.getByRole('cell', { name })).toBeVisible({ timeout: 10_000 });
	await expect(page.getByRole('link', { name, exact: true })).toBeVisible({ timeout: 10_000 });
	await page.getByRole('link', { name, exact: true }).click();
	await expect(page).toHaveURL(new RegExp(`/console/indexes/${encodeURIComponent(name)}`));
	await expect(page.getByRole('heading', { name, exact: true })).toBeVisible({ timeout: 10_000 });

	// seedIndex fixture auto-deletes in teardown
});
