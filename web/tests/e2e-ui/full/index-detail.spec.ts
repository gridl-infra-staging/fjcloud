/**
 * Full — Index Detail Tabs
 *
 * Verifies the lazy-loaded tab sections on the index detail page:
 *   - Each tab section is NOT mounted before clicking the tab
 *   - Clicking a tab renders the section with correct empty-state content
 *
 * Ownership boundary:
 *   - indexes.spec.ts: list page, create, delete, basic detail smoke
 *   - search-preview.spec.ts: Search Preview tab
 *   - THIS FILE: Settings, Documents, Dictionaries, Rules, Synonyms, Chat tabs
 */

import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';

type SeedIndexFn = (name: string, region?: string) => Promise<void>;

/**
 * Opens a tab on the index detail page and returns the section locator.
 * Asserts the section is NOT in the DOM before clicking (lazy-mount via visitedTabs),
 * then asserts it IS visible after clicking.
 */
async function openIndexDetailTab(page: Page, tabName: string, sectionTestId: string) {
	// Section must not exist in the DOM before tab click (lazy-mount via {#if visitedTabs})
	await expect(page.getByTestId(sectionTestId)).toHaveCount(0);

	// Act: click the tab
	await page.getByRole('tab', { name: tabName }).click();

	// Assert: section is now visible
	const section = page.getByTestId(sectionTestId);
	await expect(section).toBeVisible({ timeout: 10_000 });
	return section;
}

async function openSeededIndexDetailPage(
	page: Page,
	seedIndex: SeedIndexFn,
	testRegion: string,
	namePrefix: string
) {
	const indexName = `${namePrefix}-${Date.now()}`;
	await seedIndex(indexName, testRegion);
	await page.goto(`/dashboard/indexes/${encodeURIComponent(indexName)}`);
	await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 10_000 });
	return indexName;
}

test.describe('Index detail tabs', () => {
	// Each test seeds a fresh index via admin API and may absorb rate-limit backoff
	// before the detail page loader becomes stable, so 30s and 60s are both too tight.
	test.describe.configure({ timeout: 90_000 });

	test('load-and-verify: seeded detail route lazy-mounts one tab on first click', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-load-verify');

		const section = await openIndexDetailTab(page, 'Settings', 'settings-section');
		await expect(section.getByLabel('Settings JSON')).toBeVisible();
		await expect(section.getByRole('button', { name: 'Save Settings' })).toBeVisible();
	});

	test('Settings tab lazy-mounts and shows Settings JSON editor', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-settings');

		const section = await openIndexDetailTab(page, 'Settings', 'settings-section');
		await expect(section.getByLabel('Settings JSON')).toBeVisible();
		await expect(section.getByRole('button', { name: 'Save Settings' })).toBeVisible();
	});

	test('Documents tab lazy-mounts and shows upload and browse controls', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-documents');

		const section = await openIndexDetailTab(page, 'Documents', 'documents-section');
		await expect(section.getByText('Upload JSON or CSV file')).toBeVisible();
		await expect(section.getByRole('button', { name: 'Browse Documents' })).toBeVisible();
	});

	test('Dictionaries tab lazy-mounts and shows browse and add entry controls', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-dictionaries');

		const section = await openIndexDetailTab(page, 'Dictionaries', 'dictionaries-section');
		await expect(section.getByRole('heading', { name: 'Browse Entries' })).toBeVisible();
		await expect(section.getByRole('heading', { name: 'Add Entry' })).toBeVisible();
	});

	test('Rules tab lazy-mounts and shows empty state', async ({ page, seedIndex, testRegion }) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-rules');

		const section = await openIndexDetailTab(page, 'Rules', 'rules-section');
		await expect(section.getByText('No rules')).toBeVisible();
		await expect(section.getByRole('button', { name: 'Save Rule' })).toBeVisible();
	});

	test('Synonyms tab lazy-mounts and shows empty state', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-synonyms');

		const section = await openIndexDetailTab(page, 'Synonyms', 'synonyms-section');
		await expect(section.getByText('No synonyms')).toBeVisible();
		await expect(section.getByRole('button', { name: 'Save Synonym' })).toBeVisible();
	});

	test('Chat tab lazy-mounts and shows query input and empty response', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-chat');

		const section = await openIndexDetailTab(page, 'Chat', 'chat-section');
		await expect(section.getByLabel('Query')).toBeVisible();
		await expect(section.getByText('Conversation History JSON')).toBeVisible();
		await expect(section.getByText('No chat response yet.')).toBeVisible();
	});
});
