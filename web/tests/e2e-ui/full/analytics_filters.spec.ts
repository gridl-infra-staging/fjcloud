import { expect, test } from '../../fixtures/fixtures';

test.describe('Analytics filters subtab', () => {
	test.describe.configure({ timeout: 90_000 });

	test('renders filter attribute rows with applied counts and supports expand/collapse', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const indexName = `e2e-analytics-filters-${Date.now()}`;
		await seedIndex(indexName, testRegion);

		await page.route('**/console/indexes/**', async (route, request) => {
			if (
				request.method() === 'POST' &&
				request.url().includes('fetchAnalyticsFilters')
			) {
				await route.fulfill({
					status: 200,
					contentType: 'application/json',
					body: JSON.stringify({
						type: 'success',
						status: 200,
						data: '[{"analyticsFilters":1},{"filters":2},{"category":3,"brand":4},{"books":5,"movies":6},{"acme":7,"globex":8,"initech":9},50,30,120,45,10]'
					})
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
});
