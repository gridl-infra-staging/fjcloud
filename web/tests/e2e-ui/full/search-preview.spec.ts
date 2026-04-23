/**
 * Full — Search Preview
 *
 * Verifies the search preview tab on the index detail page:
 *   - Load-and-verify: Search Preview tab is visible on the detail page
 *   - Active index shows "Generate Preview Key" button
 *   - Clicking "Generate Preview Key" requests a key and shows InstantSearch
 */

import { test, expect } from '../../fixtures/fixtures';
import {
	generatePreviewKeyAndWaitForWidget,
	gotoIndexDetailWithRetry,
	getSearchPreviewReadinessSurface,
	waitForSearchPreviewReady
} from '../../fixtures/search-preview-helpers';

test.describe('Search Preview tab', () => {
	test('load-and-verify: Search Preview tab is visible on index detail page', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const name = `e2e-preview-${Date.now()}`;
		await seedIndex(name, testRegion);

		await gotoIndexDetailWithRetry(page, name);

		// smoke: intentional shell-only check for tab discoverability before interaction
		// Assert: Search Preview tab button exists
		await expect(page.getByRole('tab', { name: 'Search Preview' })).toBeVisible();
	});

	test('active index shows Generate Preview Key button when tab is opened', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const name = `e2e-preview-key-${Date.now()}`;
		await seedIndex(name, testRegion);

		await gotoIndexDetailWithRetry(page, name);

		// Act: click the Search Preview tab
		await page.getByRole('tab', { name: 'Search Preview' }).click();

		await waitForSearchPreviewReady(page);
		const { generateButton } = getSearchPreviewReadinessSurface(page);
		await expect(generateButton).toBeVisible();
	});

	test('clicking Generate Preview Key mounts InstantSearch search box', async ({
		page,
		seedSearchableIndex
	}) => {
		test.setTimeout(120_000);
		const name = `e2e-preview-gen-${Date.now()}`;
		await seedSearchableIndex(name);

		await gotoIndexDetailWithRetry(page, name);

		// Act: open Search Preview tab
		await page.getByRole('tab', { name: 'Search Preview' }).click();

		// Wait through provisioning (up to 90s) — if readiness never arrives, the test fails
		await waitForSearchPreviewReady(page);

		const section = page.getByTestId('search-preview-section');
		const generateButton = section.getByRole('button', { name: /generate preview key/i });

		// Act: click Generate Preview Key
		await generatePreviewKeyAndWaitForWidget(page);

		// Assert: search box is present inside the mounted InstantSearch widget
		await expect(page.getByTestId('instantsearch-searchbox')).toBeVisible();
	});
});
