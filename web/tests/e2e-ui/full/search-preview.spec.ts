/**
 * Full — Search Preview
 *
 * Verifies the search preview tab on the index detail page:
 *   - Load-and-verify: Search Preview tab is visible on the detail page
 *   - Active index shows "Generate Preview Key" button
 *   - Clicking "Generate Preview Key" requests a key and shows InstantSearch
 */

import { test, expect } from '../../fixtures/fixtures';
import { seedSearchableIndexForCustomer } from '../../fixtures/searchable-index';
import type { Page } from '@playwright/test';
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
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';

const SEARCHABLE_INDEX_SEED_TIMEOUT_MS = 180_000;
const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';
const API_URL = process.env.API_URL ?? 'http://localhost:3001';
const FIXTURE_PASSWORD = 'TestPassword123!';

type CreatedFixtureUser = {
	customerId: string;
	email: string;
	token: string;
};

type CreateUserFn = (email: string, password: string, name?: string) => Promise<CreatedFixtureUser>;
type LoginAsFn = (email: string, password: string) => Promise<string>;

async function seedSearchableIndexForFreshCustomer(params: {
	page: Page;
	createUser: CreateUserFn;
	loginAs: LoginAsFn;
	testRegion: string;
	namePrefix: string;
}): Promise<{ name: string; query: string; expectedHitText: string }> {
	const { page, createUser, loginAs, testRegion, namePrefix } = params;
	const seed = Date.now();
	const name = `${namePrefix}-${seed}`;
	const email = `${namePrefix}-${seed}@e2e.griddle.test`;
	const createdUser = await createUser(email, FIXTURE_PASSWORD, `Search Preview ${seed}`);
	const seeded = await seedSearchableIndexForCustomer({
		apiUrl: API_URL,
		adminKey: process.env.E2E_ADMIN_KEY,
		customerId: createdUser.customerId,
		token: createdUser.token,
		name,
		region: testRegion,
		query: 'Rust',
		expectedHitText: 'Rust'
	});
	const authToken = await loginAs(email, FIXTURE_PASSWORD);
	await page.context().clearCookies();
	await page.context().addCookies([
		{
			name: AUTH_COOKIE,
			value: authToken,
			url: BASE_URL,
			httpOnly: true,
			sameSite: 'Lax'
		}
	]);
	return seeded;
}

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
		createUser,
		loginAs,
		testRegion
	}) => {
		test.setTimeout(180_000);
		try {
			const seeded = await Promise.race([
				seedSearchableIndexForFreshCustomer({
					page,
					createUser,
					loginAs,
					testRegion,
					namePrefix: 'e2e-preview-key'
				}),
				new Promise<never>((_, reject) =>
					setTimeout(
						() =>
							reject(
								new Error(
									`seedSearchableIndex timed out after ${SEARCHABLE_INDEX_SEED_TIMEOUT_MS / 1000}s`
								)
							),
						SEARCHABLE_INDEX_SEED_TIMEOUT_MS
					)
				)
			]);
			await gotoIndexDetailWithRetry(page, seeded.name);

			// Act: click the Search Preview tab
			await page.getByRole('tab', { name: 'Search Preview' }).click();

			await waitForSearchPreviewReady(page);
			const { generateButton } = getSearchPreviewReadinessSurface(page);
			await expect(generateButton).toBeVisible();
			await generatePreviewKeyAndWaitForWidget(page);
			await submitSearchPreviewQuery(page, seeded.query);
			await waitForSearchPreviewHitsToContain(page, seeded.expectedHitText, 60_000);
		} catch (err) {
			failRequiredE2eGate(
				'active index shows Generate Preview Key button when tab is opened',
				`seedSearchableIndex failed for this environment: ${(err as Error).message}`
			);
		}
	});

	test('clicking Generate Preview Key mounts InstantSearch search box', async ({
		page,
		createUser,
		loginAs,
		testRegion
	}) => {
		test.setTimeout(180_000);
		try {
			const seeded = await Promise.race([
				seedSearchableIndexForFreshCustomer({
					page,
					createUser,
					loginAs,
					testRegion,
					namePrefix: 'e2e-preview-gen'
				}),
				new Promise<never>((_, reject) =>
					setTimeout(
						() =>
							reject(
								new Error(
									`seedSearchableIndex timed out after ${SEARCHABLE_INDEX_SEED_TIMEOUT_MS / 1000}s`
								)
							),
						SEARCHABLE_INDEX_SEED_TIMEOUT_MS
					)
				)
			]);
			await gotoIndexDetailWithRetry(page, seeded.name);

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
		} catch (err) {
			failRequiredE2eGate(
				'clicking Generate Preview Key mounts InstantSearch search box',
				`seedSearchableIndex failed for this environment: ${(err as Error).message}`
			);
		}
	});

	test('browse invariants and analytics events behave against real engine', async ({
		page,
		createUser,
		loginAs,
		testRegion
	}) => {
		test.setTimeout(240_000);
		try {
			const seeded = await Promise.race([
				seedSearchableIndexForFreshCustomer({
					page,
					createUser,
					loginAs,
					testRegion,
					namePrefix: 'e2e-preview-invariants'
				}),
				new Promise<never>((_, reject) =>
					setTimeout(
						() =>
							reject(
								new Error(
									`seedSearchableIndex timed out after ${SEARCHABLE_INDEX_SEED_TIMEOUT_MS / 1000}s`
								)
							),
						SEARCHABLE_INDEX_SEED_TIMEOUT_MS
					)
				)
			]);
			await gotoIndexDetailWithRetry(page, seeded.name);
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
			const selectedFacet = await tryFindSearchPreviewNarrowingFacet(page, preFilterHitCount);
			if (selectedFacet) {
				await toggleAndAssertFacetNarrowing(page, selectedFacet, preFilterHitCount);
			}
			await assertPaginationEdgeBehavior(page);
			await assertHighlightMarkupIsEngineBacked(page);
			await assertAnalyticsToggleContract(page);
		} catch (error) {
			failRequiredE2eGate(
				'browse invariants and analytics events behave against real engine',
				`seedSearchableIndex failed for this environment: ${(error as Error).message}`
			);
		}
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
	if (await next.isDisabled()) {
		return;
	}

	for (let iteration = 0; iteration < 20; iteration += 1) {
		if (await next.isDisabled()) {
			break;
		}
		await next.click();
	}

	await expect(next).toBeDisabled();
	await expect(previous).toBeEnabled();
}

async function tryFindSearchPreviewNarrowingFacet(
	page: Parameters<typeof waitForSearchPreviewReady>[0],
	preFilterHitCount: number
): Promise<Awaited<ReturnType<typeof findSearchPreviewNarrowingFacet>> | null> {
	try {
		return await findSearchPreviewNarrowingFacet(page, preFilterHitCount);
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		if (message.includes('No narrowing facet value found')) {
			return null;
		}
		throw error;
	}
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
	const firstHit = page
		.getByTestId('search-preview-results')
		.getByRole('button', { name: /^Open hit / })
		.first();
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
	const status = eventResponse.status();
	if (![200, 202, 204, 401, 403, 429].includes(status)) {
		const responseBody = await eventResponse.text();
		throw new Error(
			`Expected analytics /1/events status 200/202/204/401/403/429, got ${status}: ${responseBody.slice(0, 400)}`
		);
	}
	const eventPayload = eventResponse.request().postDataJSON() as {
		events?: Array<{
			eventType?: string;
			eventName?: string;
			index?: string;
			userToken?: string;
			objectIDs?: string[];
			positions?: number[];
			timestamp?: number;
		}>;
	};
	expect(Array.isArray(eventPayload.events)).toBe(true);
	expect(eventPayload.events).toHaveLength(1);
	const [event] = eventPayload.events ?? [];
	expect(event).toMatchObject({
		eventType: 'click',
		eventName: 'search_preview_result_click',
		userToken: 'search-preview',
		objectIDs: [expect.any(String)],
		positions: [expect.any(Number)]
	});
	expect(typeof event?.index).toBe('string');
	expect((event?.index ?? '').length).toBeGreaterThan(0);
	expect(typeof event?.timestamp).toBe('number');
	expect(event?.timestamp ?? 0).toBeGreaterThan(0);
}
