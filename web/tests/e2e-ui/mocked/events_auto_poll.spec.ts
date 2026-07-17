import { test, expect } from '../../fixtures/fixtures';
import { openIndexDetailTab } from '../../fixtures/index_detail_helpers';

test.describe('Events tab — auto-poll cadence', () => {
	test('fires a refreshEvents form POST roughly every 5s while polling is active', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const indexName = `e2e-events-poll-${Date.now()}`;
		await seedIndex(indexName, testRegion);

		// Count form-action POSTs to the refreshEvents action without breaking the page.
		// SvelteKit enhance posts to the same URL with `?/refreshEvents` query;
		// match the action path so we observe only the auto-poll submissions.
		let refreshPostCount = 0;
		const refreshFormDataShapes: string[] = [];
		await page.route('**/*', async (route, request) => {
			if (request.method() === 'POST' && request.url().includes('?/refreshEvents')) {
				refreshPostCount += 1;
				const post = request.postData() ?? '';
				refreshFormDataShapes.push(post);
			}
			await route.continue();
		});

		// Install Playwright's clock control before the page loads so the EventsTab
		// $effect uses the fake clock for setInterval.
		await page.clock.install();
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		await openIndexDetailTab(page, 'Events', 'events-section');

		// Auto-poll defaults to On; the live indicator is visible while polling.
		await expect(page.getByTestId('events-autopoll-toggle')).toContainText('Auto-poll: On');

		// Validate recurrence in two independent windows so this test fails if
		// polling accidentally regresses to a one-shot timer.
		await page.clock.fastForward(6_000);
		await expect.poll(() => refreshPostCount, { timeout: 5_000 }).toBeGreaterThanOrEqual(1);
		refreshPostCount = 0;
		await page.clock.fastForward(6_000);
		await expect.poll(() => refreshPostCount, { timeout: 5_000 }).toBeGreaterThanOrEqual(1);

		// Form data shape: status/eventType/limit/from/until names are present in each post.
		for (const body of refreshFormDataShapes) {
			expect(body).toContain('status=');
			expect(body).toContain('eventType=');
			expect(body).toContain('limit=');
			expect(body).toContain('from=');
			expect(body).toContain('until=');
		}
	});

	test('toggling Auto-poll Off stops the 5s polling cadence', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const indexName = `e2e-events-pollstop-${Date.now()}`;
		await seedIndex(indexName, testRegion);

		let refreshPostCount = 0;
		await page.route('**/*', async (route, request) => {
			if (request.method() === 'POST' && request.url().includes('?/refreshEvents')) {
				refreshPostCount += 1;
			}
			await route.continue();
		});

		await page.clock.install();
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		await openIndexDetailTab(page, 'Events', 'events-section');

		// Turn polling off.
		await page.getByTestId('events-autopoll-toggle').click();
		await expect(page.getByTestId('events-autopoll-toggle')).toContainText('Auto-poll: Off');

		// Reset the counter to ignore any in-flight pre-toggle requests, then advance
		// the clock past two polling intervals and assert via stable poll that zero
		// new posts arrive. expect.poll's repeated evaluation flushes microtasks
		// without violating the playwright/no-wait-for-timeout rule.
		refreshPostCount = 0;
		await page.clock.fastForward(11_000);
		await expect.poll(() => refreshPostCount, { timeout: 2_000 }).toBe(0);
	});
});
