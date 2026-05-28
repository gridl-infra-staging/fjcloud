import { expect, test } from '../../fixtures/fixtures';
import { stringify } from 'devalue';

test.describe('Analytics filters subtab', () => {
	test.describe.configure({ timeout: 90_000 });

	test('renders filter attribute rows with applied counts and supports expand/collapse', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const indexName = `e2e-analytics-filters-${Date.now()}`;
		await seedIndex(indexName, testRegion);

		await page.route('**/*', async (route) => {
			const request = route.request();
			if (request.method() === 'POST' && request.url().includes('fetchAnalyticsFilters')) {
				const payload = {
					type: 'success',
					status: 200,
					data: stringify({
						analyticsFilters: {
							filters: {
								category: { books: 50, movies: 30 },
								brand: { acme: 70, globex: 60, initech: 45 }
							}
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
			`/console/indexes/${encodeURIComponent(indexName)}?tab=analytics&subtab=filters`
		);

		await expect(page.getByTestId('tab-analytics')).toHaveAttribute('aria-selected', 'true');
		await expect(page.getByTestId('analytics-subtab-filters')).toHaveAttribute(
			'aria-selected',
			'true'
		);

		const filtersTable = page.getByTestId('filters-table');
		await expect(filtersTable).toBeVisible();

		const brandRow = page.getByTestId('filter-row-brand');
		await expect(brandRow).toContainText('brand');
		await expect(brandRow).toContainText('175');

		const categoryRow = page.getByTestId('filter-row-category');
		await expect(categoryRow).toContainText('category');
		await expect(categoryRow).toContainText('80');

		await expect(page.getByTestId('filter-values-category')).not.toBeVisible();
		await expect(page.getByTestId('filter-values-brand')).not.toBeVisible();

		await categoryRow.click();
		const categoryValues = page.getByTestId('filter-values-category');
		await expect(categoryValues).toBeVisible();
		await expect(categoryValues).toContainText('books (50)');
		await expect(categoryValues).toContainText('movies (30)');

		await categoryRow.click();
		await expect(page.getByTestId('filter-values-category')).not.toBeVisible();
	});

	test('surfaces an error when the filters action returns a malformed success payload', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const indexName = `e2e-analytics-filters-malformed-${Date.now()}`;
		await seedIndex(indexName, testRegion);

		await page.route('**/*', async (route) => {
			const request = route.request();
			if (request.method() === 'POST' && request.url().includes('fetchAnalyticsFilters')) {
				const payload = {
					type: 'success',
					status: 200,
					data: stringify({
						unexpectedFiltersEnvelope: {}
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
			`/console/indexes/${encodeURIComponent(indexName)}?tab=analytics&subtab=filters`
		);

		await expect(page.getByRole('alert')).toContainText('Failed to load filter analytics');
		await expect(page.getByTestId('filters-table')).toHaveCount(0);
		await expect(page.getByText('No filter analytics were recorded for this date range.')).toBeVisible();
	});
});
