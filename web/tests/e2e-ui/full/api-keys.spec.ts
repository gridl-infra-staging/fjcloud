/**
 * Full — API Keys
 *
 * Verifies the complete API key management surface:
 *   - Load-and-verify: seeded key appears in the keys table
 *   - Create a key through the UI form (key reveal is shown once)
 *   - Revoke a key through the UI
 */

import { test, expect } from '../../fixtures/fixtures';
import type { Page } from '@playwright/test';

async function readCreatedApiKeyFromReveal(page: Page): Promise<string> {
	const reveal = page.getByTestId('key-reveal');
	await expect(reveal).toBeVisible({ timeout: 10_000 });
	const revealText = (await reveal.textContent()) ?? '';
	const keyMatch = revealText.match(/fjc_live_[0-9a-f]{32}/);
	expect(keyMatch).not.toBeNull();
	return keyMatch ? keyMatch[0] : '';
}

test.describe('API Keys page', () => {
	test('load-and-verify: seeded key appears in the keys table', async ({ page, seedApiKey }) => {
		const name = `e2e-key-${Date.now()}`;

		// Arrange: seed via API
		await seedApiKey(name, ['search']);

		// Act: navigate to API keys page
		await page.goto('/console/api-keys');

		// Assert: page-specific heading visible
		await expect(page.getByRole('heading', { name: 'API Keys' })).toBeVisible();

		// Assert: seeded key name appears in the page body
		await expect(page.getByText(name)).toBeVisible({ timeout: 10_000 });
	});

	test('create key form is visible on the page', async ({ page }) => {
		await page.goto('/console/api-keys');

		// The create form is always visible (not toggled)
		await expect(page.getByRole('heading', { name: 'Create API Key' })).toBeVisible();
		await expect(page.getByLabel('Name')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Create key' })).toBeVisible();
	});

	test('create key through UI reveals the key value once', async ({ page, listApiKeys }) => {
		const name = `e2e-ui-key-${Date.now()}`;

		await page.goto('/console/api-keys');

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

		const apiKeys = await listApiKeys();
		expect(apiKeys.some((apiKey) => apiKey.name === name)).toBe(true);
	});

	test('create form defaults to indexes:read on first render', async ({ page }) => {
		await page.goto('/console/api-keys');

		const defaultScopeCheckbox = page.getByRole('checkbox', { name: 'Search' });
		await expect(defaultScopeCheckbox).toBeChecked();
	});

	test('create form surfaces explicit empty-scope error when all scopes are unselected', async ({
		page
	}) => {
		const name = `e2e-empty-scope-${Date.now()}`;

		await page.goto('/console/api-keys');
		await page.getByLabel('Name').fill(name);

		// Force the empty-scope path through form submission while all checkboxes are unselected.
		const scopeCheckboxes = page.getByRole('checkbox');
		const checkboxCount = await scopeCheckboxes.count();
		expect(checkboxCount).toBeGreaterThan(0);
		for (let i = 0; i < checkboxCount; i += 1) {
			await scopeCheckboxes.nth(i).uncheck();
		}
		await page.getByRole('button', { name: 'Create key' }).click();

		await expect(page.getByRole('alert')).toContainText('at least one scope is required');
	});

	test('create key through UI issues fjc_live_ key format contract', async ({ page }) => {
		const name = `e2e-ui-key-format-${Date.now()}`;

		await page.goto('/console/api-keys');
		await page.getByLabel('Name').fill(name);
		await page.getByLabel('Search').check();
		await page.getByRole('button', { name: 'Create key' }).click();

		const createdKey = await readCreatedApiKeyFromReveal(page);

		// Contract from infra/api/src/routes/api_keys.rs::generate_api_key:
		// prefix "fjc_live_" + 32 hex chars from 16 random bytes.
		expect(createdKey).toMatch(/^fjc_live_[0-9a-f]{32}$/);
		expect(createdKey).toHaveLength(41);
		console.log(
			`issued_key_sample_prefix=${createdKey.slice(0, 16)} issued_key_total_length=${createdKey.length}`
		);
	});

	test('create key through UI authenticates discover for seeded index', async ({
		page,
		discoverWithApiKey,
		seedSearchableIndex
	}) => {
		test.setTimeout(300_000);

		const name = `e2e-ui-key-auth-${Date.now()}`;
		const seededIndexName = `e2e-search-auth-${Date.now()}`;
		const seededIndex = await seedSearchableIndex(seededIndexName);

		await page.goto('/console/api-keys');
		await page.getByLabel('Name').fill(name);
		await page.getByLabel('Search').check();
		await page.getByRole('button', { name: 'Create key' }).click();

		const createdKey = await readCreatedApiKeyFromReveal(page);

		const discover = await discoverWithApiKey(seededIndex.name, createdKey);
		expect(discover.status).toBe(200);
		const discoverData = discover.body;
		expect(discoverData).not.toBeNull();
		console.log(`discover_status=${discover.status} discover_body=${JSON.stringify(discoverData)}`);
		expect(discoverData?.vm).toBeTruthy();
		expect(discoverData?.flapjack_url).toBeTruthy();
		expect(discoverData?.ttl ?? 0).toBeGreaterThan(0);
		expect(discoverData?.service_type).toBeTruthy();

		// Assert this key discovers the seeded index identity, not just "not 401":
		// the seeded index must resolve (200) while a random sibling name does not.
		const missingIndex = await discoverWithApiKey(`${seededIndex.name}-missing`, createdKey);
		expect(missingIndex.status).toBe(404);
	});

	test('revoke key removes it from the table', async ({ page, seedApiKey, listApiKeys }) => {
		const name = `e2e-revoke-${Date.now()}`;

		// Arrange: seed a key via API
		const seededKey = await seedApiKey(name, ['search']);

		await page.goto('/console/api-keys');
		await expect(page.getByText(name)).toBeVisible({ timeout: 10_000 });

		// Act: find the row for this key and click Revoke
		const keyRow = page.locator('tr').filter({ hasText: name });
		await keyRow.getByRole('button', { name: 'Revoke' }).click();

		// Assert: key disappears from the table
		await expect(page.getByText(name)).not.toBeVisible({ timeout: 5_000 });

		const apiKeys = await listApiKeys();
		expect(apiKeys.some((apiKey) => apiKey.id === seededKey.id)).toBe(false);
	});
});
