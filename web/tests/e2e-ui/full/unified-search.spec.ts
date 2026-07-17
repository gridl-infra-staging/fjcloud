/**
 * Full — Search
 *
 * Verifies the search tab on the index detail page:
 *   - Load-and-verify: Search tab is visible on the detail page
 *   - Active index mounts authenticated Search without a key prompt
 *   - Known queries return real engine results
 */

import { test, expect } from '../../fixtures/fixtures';
import { seedSearchableIndexForCustomer } from '../../fixtures/searchable-index';
import type { Page } from '@playwright/test';
import {
	failRequiredE2eGate,
	getSearchPreviewPaginationControls,
	gotoIndexDetailWithRetry,
	SEARCH_TAB_LABEL,
	SEARCH_TAB_QUERY_VALUE,
	startSearchPreviewAnalyticsCapture,
	startSearchPreviewSearchCapture,
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
	const createdUser = await createUser(email, FIXTURE_PASSWORD, `Search ${seed}`);
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

test.describe('Unified Search', () => {
	test('load-and-verify: Search tab is visible on index detail page', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const name = `e2e-preview-${Date.now()}`;
		await seedIndex(name, testRegion);

		await gotoIndexDetailWithRetry(page, name);

		const activityToggle = page.getByRole('button', { name: 'API Activity Log' });
		await expect(activityToggle).toHaveAttribute('aria-expanded', 'false');
		await activityToggle.click();
		await expect(activityToggle).toHaveAttribute('aria-expanded', 'true');
		const activityPanel = page.getByTestId('search-log-panel');
		await expect(activityPanel.getByRole('heading', { name: 'API Activity Log' })).toBeVisible();
		await expect(activityPanel.getByText('No API calls recorded')).toBeVisible();
		await activityToggle.click();
		await expect(activityPanel).toHaveCount(0);

		expect(SEARCH_TAB_LABEL).toBe('Search');
		expect(SEARCH_TAB_QUERY_VALUE).toBe('search');
		await expect(page.getByRole('tab', { name: SEARCH_TAB_LABEL })).toBeVisible();
		await page.getByRole('tab', { name: SEARCH_TAB_LABEL }).click();
		const searchSection = page.getByTestId('search-section');
		await expect(searchSection.getByRole('heading', { name: 'Search' })).toHaveCount(1);
		await expect(searchSection.getByRole('button', { name: 'Display preferences' })).toHaveCount(0);
		await expect(searchSection.getByLabel('Search as you type')).toBeVisible();
		assertCanonicalSearchTabUrl(page);
	});

	test('keeps query refine and first result in bounds at desktop width', async ({
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
					namePrefix: 'e2e-authenticated-search'
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

			await page.getByRole('tab', { name: SEARCH_TAB_LABEL }).click();
			assertCanonicalSearchTabUrl(page);

			await waitForSearchPreviewReady(page);
			await expect(page.getByRole('button', { name: /generate preview key/i })).toHaveCount(0);
			await expect(page.getByTestId('instantsearch-searchbox')).toBeVisible();
			await page.getByRole('button', { name: 'Add advanced filter' }).click();
			await expect(page.getByLabel('Advanced filter expression')).toBeVisible();
			await expect(
				page.getByText('Narrow results with an expression such as brand = "Acme" AND price < 100.')
			).toBeVisible();
			await page.getByRole('button', { name: 'Hide advanced filter' }).click();
			await submitSearchPreviewQuery(page, seeded.query);
			await waitForSearchPreviewHitsToContain(page, seeded.expectedHitText, 60_000);
			await page.mouse.wheel(0, 600);
			const viewport = page.viewportSize();
			const refineSidebar = page.getByTestId('search-refine-sidebar');
			await expect
				.poll(async () => {
					const box = await refineSidebar.boundingBox();
					return box ? box.y + box.height : Number.POSITIVE_INFINITY;
				})
				.toBeLessThanOrEqual(viewport!.height);
			const refineBox = await refineSidebar.boundingBox();
			const resultBox = await page.getByTestId('document-card').first().boundingBox();
			expect(viewport).not.toBeNull();
			expect(refineBox).not.toBeNull();
			expect(resultBox).not.toBeNull();
			await expect(refineSidebar).toHaveCSS('overflow-y', 'auto');
			expect(refineBox!.x).toBeGreaterThanOrEqual(0);
			expect(refineBox!.y + refineBox!.height).toBeLessThanOrEqual(viewport!.height);
			expect(resultBox!.x).toBeGreaterThan(refineBox!.x + refineBox!.width);
			expect(resultBox!.x + resultBox!.width).toBeLessThanOrEqual(viewport!.width);
		} catch (err) {
			failRequiredE2eGate(
				'keeps query refine and first result in bounds at desktop width',
				`seedSearchableIndex failed for this environment: ${(err as Error).message}`
			);
		}
	});

	test('opens Refine as a focus-returning drawer at 390px', async ({
		page,
		createUser,
		loginAs,
		testRegion
	}) => {
		test.setTimeout(180_000);
		try {
			await page.setViewportSize({ width: 390, height: 720 });
			const seeded = await Promise.race([
				seedSearchableIndexForFreshCustomer({
					page,
					createUser,
					loginAs,
					testRegion,
					namePrefix: 'e2e-authenticated-query'
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

			await page.getByRole('tab', { name: SEARCH_TAB_LABEL }).click();
			assertCanonicalSearchTabUrl(page);

			// Wait through provisioning (up to 90s) — if readiness never arrives, the test fails.
			await waitForSearchPreviewReady(page);
			await expect(page.getByTestId('instantsearch-searchbox')).toBeVisible();
			const refineTrigger = page.getByRole('button', { name: 'Refine (0)' });
			await expect(refineTrigger).toBeVisible();
			await expect(page.getByTestId('search-refine-sidebar')).toBeHidden();
			await refineTrigger.click();
			await expect(page.getByRole('dialog', { name: 'Refine results' })).toBeVisible();
			await page.keyboard.press('Escape');
			await expect(page.getByRole('dialog', { name: 'Refine results' })).toHaveCount(0);
			await expect(refineTrigger).toBeFocused();
			await submitSearchPreviewQuery(page, seeded.query);
			await waitForSearchPreviewHitsToContain(page, seeded.expectedHitText, 60_000);
		} catch (err) {
			failRequiredE2eGate(
				'opens Refine as a focus-returning drawer at 390px',
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
			await page.getByRole('tab', { name: SEARCH_TAB_LABEL }).click();
			assertCanonicalSearchTabUrl(page);
			await waitForSearchPreviewReady(page);
			await submitSearchPreviewQuery(page, seeded.query);
			await waitForSearchPreviewHitsToContain(page, seeded.expectedHitText, 60_000);
			await assertSearchAsYouTypePreference(page, seeded.expectedHitText);

			await assertPaginationEdgeBehavior(page);
			await assertAnalyticsToggleContract(page, seeded.query);
		} catch (error) {
			failRequiredE2eGate(
				'browse invariants and analytics events behave against real engine',
				`seedSearchableIndex failed for this environment: ${(error as Error).message}`
			);
		}
	});
});

function assertCanonicalSearchTabUrl(page: Page): void {
	const currentUrl = new URL(page.url());
	expect(currentUrl.searchParams.get('tab')).toBe(SEARCH_TAB_QUERY_VALUE);
	expect(currentUrl.searchParams.get('tab')).not.toBe('search-preview');
}

async function assertPaginationEdgeBehavior(
	page: Parameters<typeof waitForSearchPreviewReady>[0]
): Promise<void> {
	const { previous, next } = getSearchPreviewPaginationControls(page);
	await expect(previous).toBeDisabled();
	await expect(page.getByRole('button', { name: 'Page 1' })).toHaveAttribute(
		'aria-current',
		'page'
	);
	if (await next.isDisabled()) {
		await expect(next).toBeDisabled();
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
	await expect(page.getByRole('button', { name: 'Page 1' })).not.toHaveAttribute(
		'aria-current',
		'page'
	);
}

async function assertSearchAsYouTypePreference(
	page: Parameters<typeof waitForSearchPreviewReady>[0],
	expectedHitText: string
): Promise<void> {
	const checkbox = page.getByLabel('Search as you type');
	await expect(checkbox).not.toBeChecked();
	await checkbox.click();
	await expect(checkbox).toBeChecked();
	await page.reload();
	await waitForSearchPreviewReady(page);
	await waitForSearchPreviewHitsToContain(page, expectedHitText, 60_000);
	await expect(page.getByLabel('Search as you type')).toBeChecked();
}

async function assertAnalyticsToggleContract(
	page: Parameters<typeof waitForSearchPreviewReady>[0],
	query: string
): Promise<void> {
	const analyticsCapture = startSearchPreviewAnalyticsCapture(page);
	const firstHit = page
		.getByTestId('search-preview-results')
		.getByRole('button', { name: 'Open details' })
		.first();
	await firstHit.click();
	await expect
		.poll(() => analyticsCapture.payloads.length, {
			timeout: 2_000,
			message: 'Expected analytics-off clicks to emit zero preview event payloads'
		})
		.toBe(0);
	analyticsCapture.stop();
	await page.getByRole('button', { name: 'Close details' }).first().click();

	await page.getByLabel('Record preview activity in Analytics').click();
	// The toggle applies to subsequent searches; repeat the explicit query so
	// the engine returns the query ID required for a correlated result open.
	const analyticsSearchResponse = page.waitForResponse(
		(response) =>
			response.request().method() === 'POST' &&
			/\/api\/search\/[^/?]+(?:\?|$)/.test(response.url()),
		{ timeout: 30_000 }
	);
	await submitSearchPreviewQuery(page, query);
	await analyticsSearchResponse;
	const eventResponsePromise = page.waitForResponse(
		(response) =>
			response.request().method() === 'POST' &&
			/\/api\/search\/[^/]+\/events(?:\?|$)/.test(response.url()),
		{ timeout: 30_000 }
	);
	await firstHit.click();
	const eventResponse = await eventResponsePromise;
	const status = eventResponse.status();
	if (status < 200 || status >= 300) {
		const responseBody = await eventResponse.text();
		throw new Error(
			`Expected preview event delivery to succeed, got ${status}: ${responseBody.slice(0, 400)}`
		);
	}
	const eventPayload = eventResponse.request().postDataJSON() as {
		eventName?: string;
		objectID?: string;
		position?: number;
		queryID?: string;
		timestamp?: number;
		userToken?: string;
	};
	expect(eventPayload).toMatchObject({
		eventName: 'search_preview_result_opened',
		objectID: expect.any(String),
		position: expect.any(Number),
		queryID: expect.any(String),
		userToken: expect.stringMatching(/^preview-/),
		timestamp: expect.any(Number)
	});
	expect(eventPayload.position ?? 0).toBeGreaterThan(0);
	expect(eventPayload.timestamp ?? 0).toBeGreaterThan(0);

	const eventName = eventPayload.eventName!;
	const objectID = eventPayload.objectID!;
	const userToken = eventPayload.userToken!;
	await page.getByRole('button', { name: 'Close details' }).first().click();
	await page.getByRole('tab', { name: 'Events' }).click();
	const eventRow = page
		.getByRole('row')
		.filter({ hasText: eventName })
		.filter({ hasText: userToken });
	await expect
		.poll(
			async () => {
				if ((await eventRow.count()) > 0) return 1;
				const refreshResponse = page.waitForResponse(
					(response) =>
						response.request().method() === 'POST' && response.url().includes('refreshEvents'),
					{ timeout: 10_000 }
				);
				await page.getByRole('button', { name: 'Refresh', exact: true }).click();
				await refreshResponse;
				return eventRow.count();
			},
			{
				timeout: 30_000,
				message: 'Expected the query-correlated result-open event in Event Debugger'
			}
		)
		.toBe(1);
	await eventRow.click();
	const eventDetail = page.getByTestId('event-detail');
	await expect(eventDetail).toContainText(eventName);
	await expect(eventDetail).toContainText(userToken);
	await expect(eventDetail).toContainText(objectID);
}
