/**
 * Full - Migration unavailable state
 *
 * Coverage:
 *   - Authenticated customers can still open /console/migrate directly.
 *   - The page explains the temporary shutdown.
 *   - No working list/import controls or CTAs remain exposed.
 */

import { test, expect } from '../../fixtures/fixtures';

test.describe('Migration unavailable page', () => {
	test.describe.configure({ retries: 0 });

	test('authenticated direct visits show the unavailable explanation without migration actions', async ({
		page,
		arrangeTrackedCustomerSession
	}) => {
		await arrangeTrackedCustomerSession(page, { emailPrefix: 'migration-unavailable' });
		await page.goto('/console/migrate');

		await expect(page).toHaveURL(/\/console\/migrate$/);
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
});
