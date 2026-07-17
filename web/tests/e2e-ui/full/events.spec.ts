import { test, expect, type CreatedFixtureUser } from '../../fixtures/fixtures';
import { openIndexDetailTab } from '../../fixtures/index_detail_helpers';
import type { Page } from '@playwright/test';

test.use({ storageState: { cookies: [], origins: [] } });

type ArrangeTrackedCustomerSessionFn = (
	page: Page,
	options: { emailPrefix: string }
) => Promise<CreatedFixtureUser>;
type SeedCustomerIndexFn = (
	customer: CreatedFixtureUser,
	name: string,
	region?: string
) => Promise<void>;

async function openEventsTab(page: Page) {
	return await openIndexDetailTab(page, 'Events', 'events-section');
}

async function openSeededTrackedIndexDetailPage(
	page: Page,
	arrangeTrackedCustomerSession: ArrangeTrackedCustomerSessionFn,
	seedCustomerIndex: SeedCustomerIndexFn,
	testRegion: string,
	namePrefix: string
) {
	const customer = await arrangeTrackedCustomerSession(page, { emailPrefix: namePrefix });
	const indexName = `${namePrefix}-${Date.now()}`;
	await seedCustomerIndex(customer, indexName, testRegion);
	await expect(async () => {
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 10_000 });
	}).toPass({ timeout: 30_000 });
	return indexName;
}

async function waitForEventInTable(page: Page, eventName: string, timeoutMs = 15_000) {
	await expect(page.getByTestId('events-table')).toBeVisible({ timeout: timeoutMs });
	await expect(page.getByTestId('events-table').getByText(eventName).first()).toBeVisible({
		timeout: timeoutMs
	});
}

test.describe('Events tab — happy path and parity contract', () => {
	test.describe.configure({ timeout: 90_000 });

	test('happy-path: seeded events render with Index/Type/Name/User Token/Status columns', async ({
		page,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		seedEvents,
		getDebugEvents,
		testRegion
	}) => {
		const indexName = await openSeededTrackedIndexDetailPage(
			page,
			arrangeTrackedCustomerSession,
			seedCustomerIndex,
			testRegion,
			'e2e-events-happy'
		);
		const eventName = `happy-${Date.now()}`;
		await seedEvents(indexName, [
			{
				eventType: 'view',
				eventName,
				userToken: 'user-happy',
				objectIDs: ['sku-1']
			}
		]);

		// System-terminating probe: confirm the engine has the event before opening the tab.
		await expect
			.poll(async () => (await getDebugEvents(indexName)).count, { timeout: 15_000 })
			.toBeGreaterThan(0);

		await openEventsTab(page);
		await page.getByTestId('events-refresh').click();
		await waitForEventInTable(page, eventName);

		// Index column sits between Time and Type.
		await expect(page.getByRole('columnheader', { name: 'Time' })).toBeVisible();
		await expect(page.getByRole('columnheader', { name: 'Index' })).toBeVisible();
		await expect(page.getByRole('columnheader', { name: 'Type' })).toBeVisible();
		await expect(page.getByRole('columnheader', { name: 'Name' })).toBeVisible();
		await expect(page.getByRole('columnheader', { name: 'User' })).toBeVisible();
		await expect(page.getByRole('columnheader', { name: 'Status' })).toBeVisible();

		// Row carries values for the seeded event. Use ancestor `events-table` to scope
		// the row search so unrelated rows elsewhere on the page do not match.
		const row = page.getByTestId('events-table').getByRole('row').filter({ hasText: eventName });
		await expect(row).toHaveCount(1);
		await expect(row).toContainText('user-happy');
		await expect(row).toContainText('view');
		// Engine returns events with the tenant-scoped index UID, which embeds the
		// public index name; assert the row's index cell contains the seeded name.
		await expect(row).toContainText(indexName);
	});

	test('S3-1 regression: two events with identical timestamp/name/userToken both render', async ({
		page,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		seedEvents,
		testRegion
	}) => {
		const indexName = await openSeededTrackedIndexDetailPage(
			page,
			arrangeTrackedCustomerSession,
			seedCustomerIndex,
			testRegion,
			'e2e-events-s31'
		);
		const eventName = `dup-${Date.now()}`;
		const sharedTs = Date.now();
		await seedEvents(indexName, [
			{
				eventType: 'view',
				eventName,
				userToken: 'shared-user',
				objectIDs: ['obj-a'],
				timestampMs: sharedTs
			},
			{
				eventType: 'view',
				eventName,
				userToken: 'shared-user',
				objectIDs: ['obj-b'],
				timestampMs: sharedTs
			}
		]);

		await openEventsTab(page);
		await page.getByTestId('events-refresh').click();
		await waitForEventInTable(page, eventName);

		const dupRows = page
			.getByTestId('events-table')
			.getByRole('row')
			.filter({ hasText: eventName });
		await expect(dupRows).toHaveCount(2);
	});

	test('S1-2 regression: mocked 500 shows load-error card, NOT empty card', async ({
		page,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		testRegion
	}) => {
		const customer = await arrangeTrackedCustomerSession(page, { emailPrefix: 'e2e-events-s12' });
		const indexName = `e2e-events-s12-${Date.now()}`;
		await seedCustomerIndex(customer, indexName, testRegion);

		// Force the load function to surface eventsLoadError by string-injecting into the
		// SSR HTML response — same technique as events_initial_load_500.spec.ts (mocked).
		// Here we exercise it from `full/` because the assertion is end-to-end behavior
		// (load-error UI is visible AND empty-state copy is absent).
		await page.route(`**/console/indexes/${encodeURIComponent(indexName)}**`, async (route) => {
			const response = await route.fetch();
			const html = await response.text();
			if (html.includes('eventsLoadError')) {
				const patched = html.replace(
					/(eventsLoadError:)(null|"(?:\\.|[^"])*")/,
					`$1${JSON.stringify('Forced events endpoint failure')}`
				);
				await route.fulfill({
					status: response.status(),
					headers: response.headers(),
					body: patched
				});
				return;
			}
			await route.fulfill({ response });
		});

		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		await openEventsTab(page);

		await expect(page.getByTestId('events-load-error-state')).toBeVisible();
		await expect(page.getByText('No events received yet')).toHaveCount(0);
		await expect(page.getByTestId('events-retry-btn')).toBeVisible();
	});

	test('Empty state copy renders when no events match the window', async ({
		page,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		testRegion
	}) => {
		await openSeededTrackedIndexDetailPage(
			page,
			arrangeTrackedCustomerSession,
			seedCustomerIndex,
			testRegion,
			'e2e-events-empty'
		);
		await openEventsTab(page);
		// No seedEvents → engine returns zero events for the default 24h window.
		await expect(page.getByText('No events received yet')).toBeVisible();
		await expect(page.getByTestId('events-table')).toHaveCount(0);
	});

	test('Status filter narrows the table to OK events only', async ({
		page,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		seedEvents,
		testRegion
	}) => {
		const indexName = await openSeededTrackedIndexDetailPage(
			page,
			arrangeTrackedCustomerSession,
			seedCustomerIndex,
			testRegion,
			'e2e-events-filter'
		);
		const okName = `ok-${Date.now()}`;
		await seedEvents(indexName, [
			{ eventType: 'view', eventName: okName, userToken: 'u-ok', objectIDs: ['ok-1'] }
		]);

		await openEventsTab(page);
		await page.getByTestId('events-refresh').click();
		await waitForEventInTable(page, okName);

		await page.getByLabel('Status').selectOption('ok');
		await page.getByTestId('events-refresh').click();
		await expect(
			page.getByTestId('events-table').getByRole('row').filter({ hasText: okName })
		).toHaveCount(1);
	});

	test('Time range picker exposes All-available preset and disables auto-poll', async ({
		page,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		testRegion
	}) => {
		await openSeededTrackedIndexDetailPage(
			page,
			arrangeTrackedCustomerSession,
			seedCustomerIndex,
			testRegion,
			'e2e-events-range'
		);
		await openEventsTab(page);

		const rangeSelect = page.getByLabel('Time Range');
		await expect(rangeSelect.getByRole('option', { name: 'All available' })).toHaveCount(1);

		await rangeSelect.selectOption('all');
		await expect(page.getByTestId('events-autopoll-toggle')).toBeDisabled();
	});

	test('Row click opens detail panel; Close button dismisses it', async ({
		page,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		seedEvents,
		testRegion
	}) => {
		const indexName = await openSeededTrackedIndexDetailPage(
			page,
			arrangeTrackedCustomerSession,
			seedCustomerIndex,
			testRegion,
			'e2e-events-detail'
		);
		const eventName = `detail-${Date.now()}`;
		await seedEvents(indexName, [
			{ eventType: 'view', eventName, userToken: 'u-detail', objectIDs: ['det-1'] }
		]);

		await openEventsTab(page);
		await page.getByTestId('events-refresh').click();
		await waitForEventInTable(page, eventName);

		await page.getByTestId('events-table').getByRole('row').filter({ hasText: eventName }).click();
		const detail = page.getByTestId('event-detail');
		await expect(detail).toBeVisible();
		await expect(detail).toHaveAttribute('data-event-id', /.+/);
		await expect(detail).toContainText('Event Name');
		await expect(detail).toContainText('Subtype');
		await expect(detail).toContainText('User Token');
		await expect(detail).toContainText('Timestamp');

		await detail.getByRole('button', { name: 'Close' }).click();
		await expect(detail).toHaveCount(0);
	});

	test('Copy payload writes JSON to clipboard and surfaces transient Copied toast', async ({
		page,
		context,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		seedEvents,
		testRegion,
		readClipboardText
	}) => {
		await context.grantPermissions(['clipboard-read', 'clipboard-write']);

		const indexName = await openSeededTrackedIndexDetailPage(
			page,
			arrangeTrackedCustomerSession,
			seedCustomerIndex,
			testRegion,
			'e2e-events-copy'
		);
		const eventName = `copy-${Date.now()}`;
		await seedEvents(indexName, [
			{ eventType: 'view', eventName, userToken: 'u-copy', objectIDs: ['cp-1'] }
		]);

		await openEventsTab(page);
		await page.getByTestId('events-refresh').click();
		await waitForEventInTable(page, eventName);
		await page.getByTestId('events-table').getByRole('row').filter({ hasText: eventName }).click();
		await page.getByTestId('event-copy-payload').click();
		await expect(page.getByTestId('copied-toast')).toBeVisible();

		const clipboard = await readClipboardText(page);
		expect(clipboard).toContain(eventName);
		expect(clipboard).toContain('u-copy');
	});
});
