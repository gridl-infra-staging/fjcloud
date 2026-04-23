/**
 * Full — API Keys
 *
 * Verifies the complete API key management surface:
 *   - Load-and-verify: seeded key appears in the keys table
 *   - Create a key through the UI form (key reveal is shown once)
 *   - Revoke a key through the UI
 */

import { test, expect } from '../../fixtures/fixtures';

test.describe('API Keys page', () => {
	test('load-and-verify: seeded key appears in the keys table', async ({ page, seedApiKey }) => {
		const name = `e2e-key-${Date.now()}`;

		// Arrange: seed via API
		await seedApiKey(name, ['search']);

		// Act: navigate to API keys page
		await page.goto('/dashboard/api-keys');

		// Assert: page-specific heading visible
		await expect(page.getByRole('heading', { name: 'API Keys' })).toBeVisible();

		// Assert: seeded key name appears in the page body
		await expect(page.getByText(name)).toBeVisible({ timeout: 10_000 });
	});

	test('create key form is visible on the page', async ({ page }) => {
		await page.goto('/dashboard/api-keys');

		// The create form is always visible (not toggled)
		await expect(page.getByRole('heading', { name: 'Create API Key' })).toBeVisible();
		await expect(page.getByLabel('Name')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Create key' })).toBeVisible();
	});

	test('create key through UI reveals the key value once', async ({ page }) => {
		const name = `e2e-ui-key-${Date.now()}`;

		await page.goto('/dashboard/api-keys');

		// Act: fill name, check Search scope, submit
		await page.getByLabel('Name').fill(name);
		await page.getByLabel('Search').check();
		await page.getByRole('button', { name: 'Create key' }).click();

		// Assert: the key reveal banner appears with the key value
		await expect(page.getByTestId('key-reveal')).toBeVisible({ timeout: 10_000 });
		await expect(page.getByText('API key created successfully')).toBeVisible();
		await expect(page.getByText("This key won't be shown again")).toBeVisible();

		// Assert: the key name also appears in the keys table
		await expect(page.getByText(name)).toBeVisible();
	});

	test('revoke key removes it from the table', async ({ page, seedApiKey }) => {
		const name = `e2e-revoke-${Date.now()}`;

		// Arrange: seed a key via API
		await seedApiKey(name, ['search']);

		await page.goto('/dashboard/api-keys');
		await expect(page.getByText(name)).toBeVisible({ timeout: 10_000 });

		// Act: find the row for this key and click Revoke
		const keyRow = page.locator('tr').filter({ hasText: name });
		await keyRow.getByRole('button', { name: 'Revoke' }).click();

		// Assert: key disappears from the table
		await expect(page.getByText(name)).not.toBeVisible({ timeout: 5_000 });
	});
});
