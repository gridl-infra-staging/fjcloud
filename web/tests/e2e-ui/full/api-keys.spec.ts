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

async function openCreateDialog(page: Page): Promise<void> {
	await page.getByRole('button', { name: 'Create API Key' }).click();
	await expect(page.getByRole('dialog')).toBeVisible();
}

async function chooseAclScopes(page: Page, values: string[]): Promise<void> {
	await page.getByLabel('ACL').selectOption(values);
}

async function createApiKeyViaDialog(
	page: Page,
	options: {
		name: string;
		description?: string;
		indexes?: string[];
		restrictSources?: string[];
		expiresAt?: string;
		maxHitsPerQuery?: number;
		maxQueriesPerIpPerHour?: number;
		scopes?: string[];
	}
): Promise<void> {
	await openCreateDialog(page);
	await page.getByLabel('Name').fill(options.name);

	if (options.description) {
		await page.getByLabel('Description').fill(options.description);
	}
	if (options.indexes && options.indexes.length > 0) {
		const indexesInput = page.getByTestId('editor-dialog-field-indexes');
		await expect.poll(async () => {
			return await indexesInput.evaluate((element) =>
				Array.from((element as HTMLSelectElement).options).map((option) => option.value)
			);
		}, { timeout: 30_000 }).toEqual(expect.arrayContaining(options.indexes));
		await indexesInput.selectOption(options.indexes);
	}
	if (options.scopes) {
		await chooseAclScopes(page, options.scopes);
	}
	if (options.restrictSources) {
		for (const source of options.restrictSources) {
			await page.getByTestId('editor-dialog-add-restrict_sources').click();
			const rowIndex = (await page.getByTestId(/^editor-dialog-field-restrict_sources-\d+$/).count()) - 1;
			await page.getByTestId(`editor-dialog-field-restrict_sources-${rowIndex}`).fill(source);
		}
	}
	if (options.expiresAt) {
		await page.getByTestId('editor-dialog-field-expires_at').fill(options.expiresAt);
	}
	if (options.maxHitsPerQuery !== undefined) {
		await page
			.getByTestId('editor-dialog-field-max_hits_per_query')
			.fill(String(options.maxHitsPerQuery));
	}
	if (options.maxQueriesPerIpPerHour !== undefined) {
		await page
			.getByTestId('editor-dialog-field-max_queries_per_ip_per_hour')
			.fill(String(options.maxQueriesPerIpPerHour));
	}

	await page.getByRole('button', { name: 'Create key' }).click();
	await expect(page.getByText('API key created successfully')).toBeVisible({ timeout: 10_000 });
}

function apiKeyRow(page: Page, keyName: string) {
	return page.locator('tr').filter({ hasText: keyName });
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

	test('create dialog opens from the page action button', async ({ page }) => {
		await page.goto('/console/api-keys');

		await expect(page.getByRole('button', { name: 'Create API Key' })).toBeVisible();
		await openCreateDialog(page);
		await expect(page.getByLabel('Name')).toBeVisible();
		await expect(page.getByLabel('ACL')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Create key' })).toBeVisible();
	});

	test('create key through UI reveals the key value once', async ({ page, listApiKeys }) => {
		const name = `e2e-ui-key-${Date.now()}`;

		await page.goto('/console/api-keys');
		await openCreateDialog(page);

		// Act: fill name and submit through the dialog
		await page.getByLabel('Name').fill(name);
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
		await openCreateDialog(page);

		const selectedScopes = await page
			.getByLabel('ACL')
			.evaluate((element) =>
				Array.from((element as HTMLSelectElement).selectedOptions).map((option) => option.value)
			);
		expect(selectedScopes).toEqual(['indexes:read']);
	});

	test('create dialog disables save when all scopes are cleared', async ({ page }) => {
		const name = `e2e-empty-scope-${Date.now()}`;

		await page.goto('/console/api-keys');
		await openCreateDialog(page);
		await page.getByLabel('Name').fill(name);
		await chooseAclScopes(page, []);

		await expect(page.getByRole('button', { name: 'Create key' })).toBeDisabled();
	});

	test('create key through UI issues fjc_live_ key format contract', async ({ page }) => {
		const name = `e2e-ui-key-format-${Date.now()}`;

		await page.goto('/console/api-keys');
		await openCreateDialog(page);
		await page.getByLabel('Name').fill(name);
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

	test('create key through UI does not discover seeded indexes in current runtime path', async ({
		page,
		discoverWithApiKey,
		seedSearchableIndex
	}) => {
		test.setTimeout(300_000);

		const name = `e2e-ui-key-auth-${Date.now()}`;
		const seededIndexName = `searchauthidx-${Date.now()}`;
		const seededIndex = await seedSearchableIndex(seededIndexName);

		await page.goto('/console/api-keys');
		await openCreateDialog(page);
		await page.getByLabel('Name').fill(name);
		await chooseAclScopes(page, ['indexes:read', 'search']);
		await page.getByRole('button', { name: 'Create key' }).click();

		const createdKey = await readCreatedApiKeyFromReveal(page);

		const discover = await discoverWithApiKey(seededIndex.name, createdKey);
		expect(discover.status).toBe(404);

		// Runtime currently resolves management API keys through scope-only auth,
		// but discover still returns not found in this path.
		const missingIndex = await discoverWithApiKey(`${seededIndex.name}-missing`, createdKey);
		expect(missingIndex.status).toBe(404);
	});

	test('create key through UI persists lifecycle fields and renders them in table', async ({
		page,
		seedSearchableIndex
	}) => {
		const keyName = `e2e-ui-key-lifecycle-${Date.now()}`;
		const description = `Lifecycle description ${Date.now()}`;
		const seededIndex = await seedSearchableIndex(`lifecycidx-${Date.now()}`);
		const sourceRestrictions = ['10.0.0.0/24', '198.51.100.22'];
		const expiresAt = '2097-12-31T23:45';

		await page.goto('/console/api-keys');
		await createApiKeyViaDialog(page, {
			name: keyName,
			description,
			indexes: [seededIndex.name],
			restrictSources: sourceRestrictions,
			expiresAt,
			maxHitsPerQuery: 75,
			maxQueriesPerIpPerHour: 910
		});
		const expectedExpiryDisplay = await page.evaluate((expiresAtValue) => {
			return new Date(expiresAtValue).toLocaleDateString('en-US', {
				month: 'short',
				day: 'numeric',
				year: 'numeric',
				timeZone: 'UTC'
			});
		}, expiresAt);

		const keyRow = apiKeyRow(page, keyName);
		await expect(keyRow.getByText(description, { exact: true })).toBeVisible();
		await expect(keyRow.getByText(seededIndex.name, { exact: true })).toBeVisible();
		for (const source of sourceRestrictions) {
			await expect(keyRow.getByText(source, { exact: true })).toBeVisible();
		}
		await expect(keyRow.getByText('75 hits/query', { exact: true })).toBeVisible();
		await expect(keyRow.getByText('910 queries/IP/hr', { exact: true })).toBeVisible();
		await expect(keyRow.getByText('No expiry')).toHaveCount(0);
		await expect(keyRow.getByText(expectedExpiryDisplay, { exact: true })).toBeVisible();
	});

	test('index filter updates URL, preserves query params, and includes all-index keys', async ({
		page,
		seedSearchableIndex
	}) => {
		test.setTimeout(120_000);

		const keyForIndexA = `e2e-key-index-a-${Date.now()}`;
		const keyForIndexB = `e2e-key-index-b-${Date.now()}`;
		const keyForAllIndexes = `e2e-key-all-indexes-${Date.now()}`;
		const indexAName = `idxfiltera-${Date.now()}`;
		const indexBName = `idxfilterb-${Date.now()}`;
		const indexA = (await seedSearchableIndex(indexAName)).name;
		const indexB = (await seedSearchableIndex(indexBName)).name;

		await page.goto('/console/api-keys?source=e2e');
		await createApiKeyViaDialog(page, { name: keyForIndexA, indexes: [indexA] });
		await createApiKeyViaDialog(page, { name: keyForIndexB, indexes: [indexB] });
		await createApiKeyViaDialog(page, { name: keyForAllIndexes });

		const indexFilter = page.getByTestId('index-filter');
		await indexFilter.selectOption(indexA);
		await expect(page).toHaveURL(new RegExp(`/console/api-keys\\?(?:[^#]*&)?source=e2e(?:&[^#]*)?`));
		await expect(page).toHaveURL(
			new RegExp(`/console/api-keys\\?(?:[^#]*&)?index=${encodeURIComponent(indexA)}(?:&[^#]*)?`)
		);

		await expect(apiKeyRow(page, keyForIndexA)).toBeVisible();
		await expect(apiKeyRow(page, keyForAllIndexes)).toBeVisible();
		await expect(apiKeyRow(page, keyForIndexB)).toHaveCount(0);

		await indexFilter.selectOption('');
		await expect(page).toHaveURL(/\/console\/api-keys\?(?:[^#]*&)?source=e2e(?:&[^#]*)?$/);
		await expect(page).not.toHaveURL(/[?&]index=/);
		await expect(apiKeyRow(page, keyForIndexA)).toBeVisible();
		await expect(apiKeyRow(page, keyForIndexB)).toBeVisible();
		await expect(apiKeyRow(page, keyForAllIndexes)).toBeVisible();
	});

	test('copy button shows temporary copied feedback for a key row', async ({ page, seedApiKey }) => {
		const keyName = `e2e-copy-feedback-${Date.now()}`;

		await seedApiKey(keyName, ['search']);
		await page.goto('/console/api-keys');
		await page.context().grantPermissions(['clipboard-read', 'clipboard-write'], {
			origin: new URL(page.url()).origin
		});
		const copyButton = page.getByRole('button', { name: `Copy key for ${keyName}` });

		await copyButton.click();
		await expect(copyButton).toHaveText('Copied!', { timeout: 10_000 });
		await expect.poll(async () => await copyButton.textContent()).toBe('Copy');
	});

	test('revoke key removes it from the table', async ({ page, seedApiKey, listApiKeys }) => {
		const name = `e2e-revoke-${Date.now()}`;

		// Arrange: seed a key via API
		const seededKey = await seedApiKey(name, ['search']);

		await page.goto('/console/api-keys');
		await expect(page.getByText(name)).toBeVisible({ timeout: 10_000 });

		// Act: find the row for this key and confirm typed revoke
		const keyRow = page.locator('tr').filter({ hasText: name });
		await keyRow.getByRole('button', { name: `Revoke key ${name}` }).click();
		await page.getByTestId('confirm-input').fill(name);
		await page.getByTestId('confirm-confirm-btn').click();

		// Assert: key disappears from the table
		await expect(page.getByText(name)).not.toBeVisible({ timeout: 5_000 });

		const apiKeys = await listApiKeys();
		expect(apiKeys.some((apiKey) => apiKey.id === seededKey.id)).toBe(false);
	});
});
