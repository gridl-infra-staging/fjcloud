/* eslint-disable no-restricted-syntax -- visibility-pause is intrinsic browser
   behavior with no in-DOM UI to drive; arrange-phase environment manipulation
   (Object.defineProperty + document.dispatchEvent inside page.evaluate) has no
   click/keypress equivalent per browser-testing standards. */
import { test, expect } from '../../fixtures/fixtures';
import { openIndexDetailTab } from '../../fixtures/index_detail_helpers';

test.describe('Events tab — visibility pause/resume', () => {
	test('polling pauses while tab is hidden and resumes within debounce window on visible', async ({
		context,
		seedIndex,
		testRegion
	}) => {
		const indexName = `e2e-events-vis-${Date.now()}`;
		await seedIndex(indexName, testRegion);

		const eventsPage = await context.newPage();

		let refreshPostCount = 0;
		await eventsPage.route('**/*', async (route, request) => {
			if (request.method() === 'POST' && request.url().includes('?/refreshEvents')) {
				refreshPostCount += 1;
			}
			await route.continue();
		});

		await eventsPage.clock.install();
		await eventsPage.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		await openIndexDetailTab(eventsPage, 'Events', 'events-section');
		await expect(eventsPage.getByTestId('events-autopoll-toggle')).toContainText('Auto-poll: On');

		// Drive the visibility-pause path: redefine visibilityState as 'hidden' then
		// emit the visibilitychange event the EventsTab.svelte $effect listens for.
		await eventsPage.evaluate(() => {
			Object.defineProperty(document, 'visibilityState', {
				configurable: true,
				get: () => 'hidden'
			});
			document.dispatchEvent(new Event('visibilitychange'));
		});

		// Reset the counter and confirm no posts arrive across two polling intervals.
		refreshPostCount = 0;
		await eventsPage.clock.fastForward(11_000);
		await expect.poll(() => refreshPostCount, { timeout: 2_000 }).toBe(0);

		// Flip visibility back to 'visible'; the $effect re-arms the interval after
		// a 200ms debounce and fires an immediate refresh on visible.
		await eventsPage.evaluate(() => {
			Object.defineProperty(document, 'visibilityState', {
				configurable: true,
				get: () => 'visible'
			});
			document.dispatchEvent(new Event('visibilitychange'));
		});

		// Resume path rearms interval after 200ms debounce; allow one full poll interval.
		await eventsPage.clock.fastForward(5_500);
		await expect.poll(() => refreshPostCount, { timeout: 5_000 }).toBeGreaterThanOrEqual(1);
	});
});
