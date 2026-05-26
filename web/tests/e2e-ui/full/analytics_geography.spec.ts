import { expect, test } from '../../fixtures/fixtures';

test.describe('Analytics geography subtab', () => {
	test.describe.configure({ timeout: 90_000 });

	test('renders countries table and preserves drill-down in URL state', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const indexName = `e2e-analytics-geography-${Date.now()}`;
		await seedIndex(indexName, testRegion);

		await page.route('**/console/indexes/**', async (route, request) => {
			if (request.method() === 'POST' && request.url().includes('fetchAnalyticsCountries')) {
				await route.fulfill({
					status: 200,
					contentType: 'application/json',
					body: JSON.stringify({
						type: 'success',
						status: 200,
						data: '[{"analyticsCountries":1},{"countries":2},{"US":3,"FR":4,"DE":5},100,37,22]'
					})
				});
				return;
			}

			await route.continue();
		});

		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=analytics&subtab=geography`);

		await expect(page.getByTestId('tab-analytics')).toHaveAttribute('aria-selected', 'true');
		await expect(page.getByTestId('analytics-subtab-geography')).toHaveAttribute(
			'aria-selected',
			'true'
		);

		const countriesTable = page.getByTestId('geo-countries-table');
		await expect(countriesTable).toBeVisible();
		await expect(countriesTable.getByTestId('geo-country-row-US')).toContainText('100');

		await countriesTable.getByTestId('geo-country-row-US').click();
		const countryDetail = page.getByTestId('geo-country-detail');
		await expect(countryDetail).toBeVisible();
		await expect(countryDetail.getByRole('heading', { level: 3 })).toContainText('United States');
		expect(new URL(page.url()).searchParams.get('country')).toBe('US');

		await page.reload();
		await expect(page.getByTestId('geo-country-detail')).toBeVisible();
		expect(new URL(page.url()).searchParams.get('country')).toBe('US');

		await page.getByTestId('geo-country-back').click();
		await expect(page.getByTestId('geo-countries-table')).toBeVisible();
		expect(new URL(page.url()).searchParams.get('country')).toBeNull();
	});
});
