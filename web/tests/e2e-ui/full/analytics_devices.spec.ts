import { expect, test } from '../../fixtures/fixtures';

test.describe('Analytics devices subtab', () => {
	test.describe.configure({ timeout: 90_000 });

	test('renders deterministic device counts from fetchAnalyticsDevices action', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const indexName = `e2e-analytics-devices-${Date.now()}`;
		await seedIndex(indexName, testRegion);

		await page.route('**/console/indexes/**', async (route, request) => {
			if (request.method() === 'POST' && request.url().includes('fetchAnalyticsDevices')) {
				await route.fulfill({
					status: 200,
					contentType: 'application/json',
					body: JSON.stringify({
						type: 'success',
						status: 200,
						data: '[{\"analyticsDevices\":1},{\"devices\":2},{\"desktop\":3,\"mobile\":4,\"tablet\":5},42,17,8]'
					})
				});
				return;
			}

			await route.continue();
		});

		await page.goto(
			`/console/indexes/${encodeURIComponent(indexName)}?tab=analytics&subtab=devices`
		);

		await expect(page.getByTestId('tab-analytics')).toHaveAttribute('aria-selected', 'true');
		await expect(page.getByTestId('analytics-subtab-devices')).toHaveAttribute(
			'aria-selected',
			'true'
		);
		await expect(page.getByTestId('device-card-desktop')).toContainText('42');
		await expect(page.getByTestId('device-card-mobile')).toContainText('17');
		await expect(page.getByTestId('device-card-tablet')).toContainText('8');
		await expect(page.getByTestId('devices-bar-chart')).toBeVisible();
	});
});
