import { expect, test } from '../../fixtures/fixtures';
import { stringify } from 'devalue';

test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Analytics geography subtab', () => {
	test.describe.configure({ timeout: 90_000 });

	test('renders countries table and preserves drill-down in URL state', async ({
		page,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		testRegion
	}) => {
		const customer = await arrangeTrackedCustomerSession(page, {
			emailPrefix: 'e2e-analytics-geography'
		});
		const indexName = `e2e-analytics-geography-${Date.now()}`;
		await seedCustomerIndex(customer, indexName, testRegion);

		await page.route('**/*', async (route) => {
			const request = route.request();
			if (request.method() === 'POST' && request.url().includes('fetchAnalyticsCountries')) {
				const payload = {
					type: 'success',
					status: 200,
					data: stringify({
						analyticsCountries: {
							countries: { US: 100, FR: 37, DE: 22 }
						}
					})
				};
				await route.fulfill({
					status: 200,
					contentType: 'application/json',
					body: JSON.stringify(payload)
				});
				return;
			}

			await route.continue();
		});

		await page.goto(
			`/console/indexes/${encodeURIComponent(indexName)}?tab=analytics&subtab=geography`
		);

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

	test('surfaces an error when the geography action returns a malformed success payload', async ({
		page,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		testRegion
	}) => {
		const customer = await arrangeTrackedCustomerSession(page, {
			emailPrefix: 'e2e-analytics-geography-malformed'
		});
		const indexName = `e2e-analytics-geography-malformed-${Date.now()}`;
		await seedCustomerIndex(customer, indexName, testRegion);

		await page.route('**/*', async (route) => {
			const request = route.request();
			if (request.method() === 'POST' && request.url().includes('fetchAnalyticsCountries')) {
				const payload = {
					type: 'success',
					status: 200,
					data: stringify({
						unexpectedCountriesEnvelope: {}
					})
				};
				await route.fulfill({
					status: 200,
					contentType: 'application/json',
					body: JSON.stringify(payload)
				});
				return;
			}

			await route.continue();
		});

		await page.goto(
			`/console/indexes/${encodeURIComponent(indexName)}?tab=analytics&subtab=geography`
		);

		await expect(page.getByRole('alert')).toContainText('Failed to load geography analytics');
		await expect(page.getByTestId('geo-countries-table')).toHaveCount(0);
		await expect(
			page.getByText('No country analytics were recorded for this date range.')
		).toBeVisible();
	});
});
