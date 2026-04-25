import type { BrowserContext, Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import {
	generatePreviewKeyAndWaitForWidget,
	SEARCH_PREVIEW_READY_MESSAGE,
	SEARCH_PREVIEW_READY_TIMEOUT_MS,
	getSearchPreviewReadinessSurface,
	submitSearchPreviewQuery
} from '../../fixtures/search-preview-helpers';
import {
	seedIndexForCustomerViaAdmin,
	seedSearchableIndexForCustomer
} from '../../fixtures/searchable-index';
import { AUTH_COOKIE } from '../../../src/lib/server/auth-session-contracts';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173';
const API_URL = process.env.API_URL ?? 'http://localhost:3001';

async function setAuthCookie(context: BrowserContext, token: string): Promise<void> {
	await context.addCookies([
		{
			name: AUTH_COOKIE,
			value: token,
			url: BASE_URL,
			httpOnly: true,
			sameSite: 'Lax'
		}
	]);
}

// Isolation keeps this local variant because each poll iteration must force-tab
// into Search Preview after user/context switches; the shared helper assumes the
// tab is already selected and would miss these transitions in this spec.
async function waitForSearchPreviewReady(page: Page): Promise<void> {
	const { generateButton } = getSearchPreviewReadinessSurface(page);

	await expect
		.poll(
			async () => {
				await page.getByRole('tab', { name: 'Search Preview' }).click();
				return generateButton.isVisible().catch(() => false);
			},
			{
				timeout: SEARCH_PREVIEW_READY_TIMEOUT_MS,
				message: SEARCH_PREVIEW_READY_MESSAGE
			}
		)
		.toBe(true);
}

test.describe('Cross-tenant index isolation', () => {
	test.use({ storageState: { cookies: [], origins: [] } });
	test.describe.configure({ timeout: 120_000 });

	test('users with identically named indexes only see their own index metadata', async ({
		page,
		browser,
		createUser,
		loginAs,
		testRegion
	}) => {
		const password = 'TestPassword123!';
		const seed = Date.now();
		const sharedIndexName = `iso-shared-${seed}`;
		const userAHit = `Isolation List User A Document ${seed}`;
		const userBHit = `Isolation List User B Document ${seed}`;

		const userA = await createUser(
			`iso-a-${seed}@e2e.griddle.test`,
			password,
			`Isolation User A ${seed}`
		);
		const userB = await createUser(
			`iso-b-${seed}@e2e.griddle.test`,
			password,
			`Isolation User B ${seed}`
		);

		await seedSearchableIndexForCustomer({
			apiUrl: API_URL,
			adminKey: process.env.E2E_ADMIN_KEY,
			customerId: userA.customerId,
			token: userA.token,
			name: sharedIndexName,
			region: testRegion,
			query: userAHit,
			expectedHitText: userAHit,
			documents: [
				{ objectID: `iso-list-a-doc-1-${seed}`, title: userAHit, body: 'user-a-only-content-1' },
				{
					objectID: `iso-list-a-doc-2-${seed}`,
					title: `${userAHit} Two`,
					body: 'user-a-only-content-2'
				}
			]
		});
		await seedSearchableIndexForCustomer({
			apiUrl: API_URL,
			adminKey: process.env.E2E_ADMIN_KEY,
			customerId: userB.customerId,
			token: userB.token,
			name: sharedIndexName,
			region: testRegion,
			query: userBHit,
			expectedHitText: userBHit,
			documents: [
				{ objectID: `iso-list-b-doc-1-${seed}`, title: userBHit, body: 'user-b-only-content-1' }
			]
		});

		const userAToken = await loginAs(userA.email, password);
		await setAuthCookie(page.context(), userAToken);

		await page.goto(`${BASE_URL}/dashboard/indexes/${encodeURIComponent(sharedIndexName)}`);
		await expect(page.getByRole('heading', { name: sharedIndexName })).toBeVisible();

		const statsSection = page.getByTestId('stats-section');
		await expect(statsSection.getByTestId('stat-entries-value')).toHaveText('2');
		await expect(statsSection.getByTestId('stat-entries-value')).not.toHaveText('1');
		await expect(statsSection.getByTestId('stat-region-value')).toHaveText(testRegion);

		const userBContext = await browser.newContext();
		const userBPage = await userBContext.newPage();
		try {
			const userBToken = await loginAs(userB.email, password);
			await setAuthCookie(userBContext, userBToken);

			await userBPage.goto(`${BASE_URL}/dashboard/indexes/${encodeURIComponent(sharedIndexName)}`);
			await expect(userBPage.getByRole('heading', { name: sharedIndexName })).toBeVisible();

			const userBStatsSection = userBPage.getByTestId('stats-section');

			await expect(userBStatsSection.getByTestId('stat-entries-value')).toHaveText('1');
			await expect(userBStatsSection.getByTestId('stat-entries-value')).not.toHaveText('2');
			await expect(userBStatsSection.getByTestId('stat-region-value')).toHaveText(testRegion);
		} finally {
			await userBContext.close();
		}
	});

	test('search preview stays tenant-scoped for identically named indexes', async ({
		page,
		browser,
		createUser,
		loginAs,
		testRegion
	}) => {
		test.setTimeout(180_000);
		const password = 'TestPassword123!';
		const seed = Date.now();
		const sharedIndexName = `iso-search-shared-${seed}`;
		const userAHit = `Isolation User A Document ${seed}`;
		const userBHit = `Isolation User B Document ${seed}`;

		const userA = await createUser(
			`iso-search-a-${seed}@e2e.griddle.test`,
			password,
			`Isolation Search A ${seed}`
		);
		const userB = await createUser(
			`iso-search-b-${seed}@e2e.griddle.test`,
			password,
			`Isolation Search B ${seed}`
		);

		await seedSearchableIndexForCustomer({
			apiUrl: API_URL,
			adminKey: process.env.E2E_ADMIN_KEY,
			customerId: userA.customerId,
			token: userA.token,
			name: sharedIndexName,
			region: testRegion,
			query: 'Isolation',
			expectedHitText: userAHit,
			documents: [{ objectID: `iso-a-doc-${seed}`, title: userAHit, body: 'user-a-only-content' }]
		});
		await seedSearchableIndexForCustomer({
			apiUrl: API_URL,
			adminKey: process.env.E2E_ADMIN_KEY,
			customerId: userB.customerId,
			token: userB.token,
			name: sharedIndexName,
			region: testRegion,
			query: 'Isolation',
			expectedHitText: userBHit,
			documents: [{ objectID: `iso-b-doc-${seed}`, title: userBHit, body: 'user-b-only-content' }]
		});

		const userAToken = await loginAs(userA.email, password);
		await setAuthCookie(page.context(), userAToken);

		await page.goto(`/dashboard/indexes/${encodeURIComponent(sharedIndexName)}`);
		await expect(page.getByRole('heading', { name: sharedIndexName })).toBeVisible();
		await waitForSearchPreviewReady(page);
		await generatePreviewKeyAndWaitForWidget(page);
		await submitSearchPreviewQuery(page, 'Isolation');
		await expect
			.poll(async () => page.getByTestId('instantsearch-hits').textContent(), {
				timeout: 60_000,
				message: `Waiting for hits to include ${userAHit}`
			})
			.toContain(userAHit);
		await expect(page.getByTestId('instantsearch-hits').getByText(userBHit)).toHaveCount(0);

		const userBContext = await browser.newContext();
		const userBPage = await userBContext.newPage();
		try {
			const userBToken = await loginAs(userB.email, password);
			await setAuthCookie(userBContext, userBToken);

			await userBPage.goto(`${BASE_URL}/dashboard/indexes/${encodeURIComponent(sharedIndexName)}`);
			await expect(userBPage.getByRole('heading', { name: sharedIndexName })).toBeVisible();
			await waitForSearchPreviewReady(userBPage);
			await generatePreviewKeyAndWaitForWidget(userBPage);
			await submitSearchPreviewQuery(userBPage, 'Isolation');
			await expect
				.poll(async () => userBPage.getByTestId('instantsearch-hits').textContent(), {
					timeout: 60_000,
					message: `Waiting for hits to include ${userBHit}`
				})
				.toContain(userBHit);
			await expect(userBPage.getByTestId('instantsearch-hits').getByText(userAHit)).toHaveCount(0);
		} finally {
			await userBContext.close();
		}
	});

	test('user A cannot access a user-B-only index detail route', async ({
		page,
		createUser,
		loginAs,
		testRegion
	}) => {
		const password = 'TestPassword123!';
		const seed = Date.now();
		const userBOnlyIndex = `iso-b-only-${seed}`;

		const userA = await createUser(
			`iso-route-a-${seed}@e2e.griddle.test`,
			password,
			`Isolation Route A ${seed}`
		);
		const userB = await createUser(
			`iso-route-b-${seed}@e2e.griddle.test`,
			password,
			`Isolation Route B ${seed}`
		);

		await seedIndexForCustomerViaAdmin({
			apiUrl: API_URL,
			adminKey: process.env.E2E_ADMIN_KEY,
			customerId: userB.customerId,
			token: userB.token,
			name: userBOnlyIndex,
			region: testRegion
		});

		const userAToken = await loginAs(userA.email, password);
		await setAuthCookie(page.context(), userAToken);

		await page.goto(`/dashboard/indexes/${encodeURIComponent(userBOnlyIndex)}`);
		await expect(page.getByText('404')).toBeVisible();
		await expect(page.getByRole('heading', { name: /not found/i })).toBeVisible();
		await expect(page.getByText(userBOnlyIndex)).toHaveCount(0);
	});
});
