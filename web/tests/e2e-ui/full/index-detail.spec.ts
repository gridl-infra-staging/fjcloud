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
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
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
		await expect(section.getByRole('heading', { name: 'Rules' })).toBeVisible();
		await expect(section.getByRole('heading', { name: 'Add or Update Rule' })).toBeVisible();
		await expect(section.getByLabel('Object ID')).toBeVisible();
		await expect(section.getByRole('button', { name: 'Save Rule' })).toBeVisible();
	});

	test('Synonyms tab lazy-mounts and shows empty state', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-synonyms');

		const section = await openIndexDetailTab(page, 'Synonyms', 'synonyms-section');
		await expect(section.getByRole('heading', { name: 'Synonyms' })).toBeVisible();
		await expect(section.getByRole('heading', { name: 'Add or Update Synonym' })).toBeVisible();
		await expect(section.getByLabel('Object ID')).toBeVisible();
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

	test('tab strip uses desktop overflow, mobile stacking, and keyboard tab order guard', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await page.setViewportSize({ width: 1024, height: 900 });
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-tab-overflow');

		const tabsStrip = page.getByTestId('index-tabs-strip');
		await expect(tabsStrip).toBeVisible();
		await expect
			.poll(async () => tabsStrip.evaluate((node) => getComputedStyle(node).overflowX))
			.toBe('auto');
		await expect
			.poll(async () => tabsStrip.evaluate((node) => getComputedStyle(node).scrollSnapType))
			.toBe('x mandatory');

		const desktopSize = await tabsStrip.evaluate((node) => ({
			scrollWidth: node.scrollWidth,
			clientWidth: node.clientWidth
		}));
		expect(desktopSize.scrollWidth).toBeGreaterThan(desktopSize.clientWidth);
		for (const tabTestId of ['tab-overview', 'tab-settings', 'tab-documents']) {
			await expect
				.poll(async () =>
					page.getByTestId(tabTestId).evaluate((node) => getComputedStyle(node).scrollSnapAlign)
				)
				.toBe('start');
		}

		const leftFade = page.getByTestId('index-tabs-fade-left');
		const rightFade = page.getByTestId('index-tabs-fade-right');
		await expect(leftFade).toBeVisible();
		await expect(rightFade).toBeVisible();
		await expect
			.poll(async () => leftFade.evaluate((node) => getComputedStyle(node).pointerEvents))
			.toBe('none');
		await expect
			.poll(async () => rightFade.evaluate((node) => getComputedStyle(node).pointerEvents))
			.toBe('none');

		const desktopInteraction = await tabsStrip.evaluate((node) => ({
			scrollWidth: node.scrollWidth,
			clientWidth: node.clientWidth
		}));
		expect(desktopInteraction.scrollWidth).toBeGreaterThan(desktopInteraction.clientWidth);

		const leftBoundaryTabVisibleBeyondFade = await page.evaluate(() => {
			const strip = document.querySelector('[data-testid="index-tabs-strip"]');
			const leftFade = document.querySelector('[data-testid="index-tabs-fade-left"]');
			const leftTab = document.querySelector('[data-testid="tab-overview"]');
			if (
				!(strip instanceof HTMLElement) ||
				!(leftFade instanceof HTMLElement) ||
				!(leftTab instanceof HTMLElement)
			) {
				return false;
			}

			leftTab.scrollIntoView({ inline: 'start', block: 'nearest' });
			const stripRect = strip.getBoundingClientRect();
			const fadeRect = leftFade.getBoundingClientRect();
			const tabRect = leftTab.getBoundingClientRect();
			const visibleWithinStrip =
				tabRect.left >= stripRect.left - 1 && tabRect.right <= stripRect.right + 1;
			const clearOfLeftFade = tabRect.left >= Math.max(stripRect.left, fadeRect.right) - 1;
			return visibleWithinStrip && clearOfLeftFade;
		});
		expect(leftBoundaryTabVisibleBeyondFade).toBe(true);

		const rightmostTabVisibleBeyondFade = await page.evaluate(() => {
			const strip = document.querySelector('[data-testid="index-tabs-strip"]');
			const rightFade = document.querySelector('[data-testid="index-tabs-fade-right"]');
			const rightTab = document.querySelector('[data-testid="tab-search-preview"]');
			if (
				!(strip instanceof HTMLElement) ||
				!(rightFade instanceof HTMLElement) ||
				!(rightTab instanceof HTMLElement)
			) {
				return false;
			}

			rightTab.scrollIntoView({ inline: 'end', block: 'nearest' });
			strip.scrollLeft = strip.scrollWidth;
			const stripRect = strip.getBoundingClientRect();
			const fadeRect = rightFade.getBoundingClientRect();
			const tabRect = rightTab.getBoundingClientRect();
			const visibleWithinStrip =
				tabRect.left >= stripRect.left - 1 && tabRect.right <= stripRect.right + 1;
			const clearOfRightFade = tabRect.right <= Math.min(stripRect.right, fadeRect.left) + 1;
			return visibleWithinStrip && clearOfRightFade;
		});
		expect(rightmostTabVisibleBeyondFade).toBe(true);

		await page.setViewportSize({ width: 480, height: 900 });
		await expect
			.poll(async () => tabsStrip.evaluate((node) => getComputedStyle(node).flexDirection))
			.toBe('column');
		const mobileSize = await tabsStrip.evaluate((node) => ({
			scrollWidth: node.scrollWidth,
			clientWidth: node.clientWidth
		}));
		expect(mobileSize.scrollWidth).toBeLessThanOrEqual(mobileSize.clientWidth);

		const expectedFocusOrder = ['tab-overview', 'tab-settings', 'tab-documents'];
		await page.getByTestId('tab-overview').focus();
		for (const tabTestId of expectedFocusOrder) {
			await expect(page.getByTestId(tabTestId)).toBeFocused();
			await page.keyboard.press('Tab');
		}
	});
});
