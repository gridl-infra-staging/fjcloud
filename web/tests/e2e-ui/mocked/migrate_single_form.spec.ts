import { test, expect } from '../../fixtures/fixtures';

test('mocked migrate route shows the unavailable state and no migration form controls', async ({
	page
}) => {
	await page.goto('/console/migrate');

	await expect(page.getByRole('heading', { name: 'Migrate from Algolia' })).toBeVisible();
	await expect(page.getByTestId('migration-unavailable')).toContainText(
		'Algolia migration is temporarily unavailable'
	);
	await expect(page.getByText(/temporarily turned off new Algolia imports/i)).toBeVisible();

	await expect(page.getByLabel('App ID')).toHaveCount(0);
	await expect(page.getByLabel('API Key')).toHaveCount(0);
	await expect(page.getByRole('button', { name: 'Browse indexes' })).toHaveCount(0);
	await expect(page.getByTestId('migrate-button')).toHaveCount(0);
});
