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
	collectVisibleSearchPreviewCardTexts,
	collectVisibleSearchPreviewHighlightHtml,
	countSearchPreviewHits,
	failRequiredE2eGate,
	findSearchPreviewNarrowingFacet,
	generatePreviewKeyAndWaitForWidget,
	getSearchPreviewPaginationControls,
	gotoIndexDetailWithRetry,
	startSearchPreviewAnalyticsCapture,
	toggleSearchPreviewFacet,
	getSearchPreviewReadinessSurface,
	submitSearchPreviewQuery,
	waitForSearchPreviewHitsToContain,
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
		seedSearchableIndex
	}) => {
		test.setTimeout(180_000);
		const name = `e2e-preview-key-${Date.now()}`;
		let seeded: { query: string; expectedHitText: string };
		try {
			seeded = await Promise.race([
				seedSearchableIndex(name),
				new Promise<never>((_, reject) =>
					setTimeout(() => reject(new Error('seedSearchableIndex timed out after 90s')), 90_000)
				)
			]);
		} catch (err) {
			failRequiredE2eGate(
				'active index shows Generate Preview Key button when tab is opened',
				`seedSearchableIndex failed for this environment: ${(err as Error).message}`
			);
		}

		await gotoIndexDetailWithRetry(page, name);

		// Act: click the Search Preview tab
		await page.getByRole('tab', { name: 'Search Preview' }).click();

		await waitForSearchPreviewReady(page);
		const { generateButton } = getSearchPreviewReadinessSurface(page);
		await expect(generateButton).toBeVisible();
		await generatePreviewKeyAndWaitForWidget(page);
		await submitSearchPreviewQuery(page, seeded.query);
		await waitForSearchPreviewHitsToContain(page, seeded.expectedHitText, 60_000);
	});

	test('clicking Generate Preview Key mounts InstantSearch search box', async ({
		page,
		seedSearchableIndex
	}) => {
		test.setTimeout(180_000);
		const name = `e2e-preview-gen-${Date.now()}`;
		let seeded: { query: string; expectedHitText: string };
		try {
			seeded = await Promise.race([
				seedSearchableIndex(name),
				new Promise<never>((_, reject) =>
					setTimeout(() => reject(new Error('seedSearchableIndex timed out after 90s')), 90_000)
				)
			]);
		} catch (err) {
			failRequiredE2eGate(
				'clicking Generate Preview Key mounts InstantSearch search box',
				`seedSearchableIndex failed for this environment: ${(err as Error).message}`
			);
		}

		await gotoIndexDetailWithRetry(page, name);

		// Act: open Search Preview tab
		await page.getByRole('tab', { name: 'Search Preview' }).click();

		// Wait through provisioning (up to 90s) — if readiness never arrives, the test fails
		await waitForSearchPreviewReady(page);

		// Act: click Generate Preview Key
		await generatePreviewKeyAndWaitForWidget(page);

		// Assert: search box is present inside the mounted InstantSearch widget
		await expect(page.getByTestId('instantsearch-searchbox')).toBeVisible();
		await submitSearchPreviewQuery(page, seeded.query);
		await waitForSearchPreviewHitsToContain(page, seeded.expectedHitText, 60_000);
	});

	test('browse invariants and analytics events behave against real engine', async ({
		page,
		seedSearchableIndex
	}) => {
		test.setTimeout(240_000);
		const name = `e2e-preview-invariants-${Date.now()}`;
		let seeded: { query: string; expectedHitText: string };
		try {
			seeded = await Promise.race([
				seedSearchableIndex(name),
				new Promise<never>((_, reject) =>
					setTimeout(() => reject(new Error('seedSearchableIndex timed out after 90s')), 90_000)
				)
			]);
		} catch (error) {
			failRequiredE2eGate(
				'browse invariants and analytics events behave against real engine',
				`seedSearchableIndex failed for this environment: ${(error as Error).message}`
			);
		}

		await gotoIndexDetailWithRetry(page, name);
		await page.getByRole('tab', { name: 'Search Preview' }).click();
		await page.evaluate(() => {
			const nextUrl = new URL(window.location.href);
			nextUrl.searchParams.set('hr', '1');
			window.history.replaceState(window.history.state, '', nextUrl);
		});

		await waitForSearchPreviewReady(page);
		await generatePreviewKeyAndWaitForWidget(page);
		await submitSearchPreviewQuery(page, seeded.query);
		await waitForSearchPreviewHitsToContain(page, seeded.expectedHitText, 60_000);

		const preFilterHitCount = await countSearchPreviewHits(page);
		const selectedFacet = await findSearchPreviewNarrowingFacet(page, preFilterHitCount);
		await toggleAndAssertFacetNarrowing(page, selectedFacet, preFilterHitCount);
		await assertPaginationEdgeBehavior(page);
		await assertHighlightMarkupIsEngineBacked(page);
		await assertAnalyticsToggleContract(page);
	});
});

async function toggleAndAssertFacetNarrowing(
	page: Parameters<typeof waitForSearchPreviewReady>[0],
	selectedFacet: Awaited<ReturnType<typeof findSearchPreviewNarrowingFacet>>,
	preFilterHitCount: number
): Promise<void> {
	await submitFacetAndAwaitResults(page, selectedFacet.label);
	const postFilterHitCount = await countSearchPreviewHits(page);
	expect(postFilterHitCount).toBeGreaterThan(0);
	expect(postFilterHitCount).toBeLessThan(preFilterHitCount);

	const cardTexts = await collectVisibleSearchPreviewCardTexts(page);
	expect(cardTexts.length).toBeGreaterThan(0);
	for (const cardText of cardTexts) {
		expect(cardText).toContain(selectedFacet.value);
	}
}

async function submitFacetAndAwaitResults(
	page: Parameters<typeof waitForSearchPreviewReady>[0],
	facetLabel: string
): Promise<void> {
	await toggleSearchPreviewFacet(page, facetLabel);
	await expect(page.getByTestId('search-preview-results-skeleton')).toHaveCount(0, {
		timeout: 30_000
	});
}

async function assertPaginationEdgeBehavior(
	page: Parameters<typeof waitForSearchPreviewReady>[0]
): Promise<void> {
	const { previous, next } = getSearchPreviewPaginationControls(page);
	await expect(previous).toBeDisabled();
	await expect(next).toBeEnabled();

	for (let iteration = 0; iteration < 20; iteration += 1) {
		if (await next.isDisabled()) {
			break;
		}
		await next.click();
	}

	await expect(next).toBeDisabled();
	await expect(previous).toBeEnabled();
}

async function assertHighlightMarkupIsEngineBacked(
	page: Parameters<typeof waitForSearchPreviewReady>[0]
): Promise<void> {
	const highlights = await collectVisibleSearchPreviewHighlightHtml(page);
	expect(highlights.length).toBeGreaterThan(0);
	expect(highlights.some((html) => html.includes('<em>'))).toBe(true);
}

async function assertAnalyticsToggleContract(
	page: Parameters<typeof waitForSearchPreviewReady>[0]
): Promise<void> {
	const analyticsCapture = startSearchPreviewAnalyticsCapture(page);
	const firstHit = page.getByTestId('search-preview-results').getByRole('button').first();
	await firstHit.click();
	await expect
		.poll(() => analyticsCapture.payloads.length, {
			timeout: 2_000,
			message: 'Expected analytics-off clicks to emit zero /1/events payloads'
		})
		.toBe(0);
	analyticsCapture.stop();

	await page.getByLabel('Track analytics events').click();
	const eventResponsePromise = page.waitForResponse((response) => {
		return response.request().method() === 'POST' && response.url().includes('/1/events');
	});
	await firstHit.click();
	const eventResponse = await eventResponsePromise;
	expect(eventResponse.ok()).toBe(true);
	const eventPayload = eventResponse.request().postDataJSON() as {
		type?: string;
		query?: string;
		indexName?: string;
		metadata?: Record<string, unknown>;
	};

	expect(eventPayload.type).toBe('search_preview_result_click');
	expect(typeof eventPayload.query).toBe('string');
	expect((eventPayload.query ?? '').length).toBeGreaterThan(0);
	expect(typeof eventPayload.indexName).toBe('string');
	expect(eventPayload.metadata).toMatchObject({
		objectID: expect.any(String),
		page: expect.any(Number)
	});
}
