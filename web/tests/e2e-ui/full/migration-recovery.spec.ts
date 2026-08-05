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
		// Heading and paused-imports copy dropped "Algolia" when the console gained
		// Meilisearch and Typesense sources. The unavailable message stays Algolia-worded
		// because it is server-owned (infra/api/src/routes/migration.rs:32) and rendered
		// verbatim, so it is asserted exactly as the API publishes it.
		await expect(page.getByRole('heading', { name: 'Migrate search data' })).toBeVisible();
		await expect(page.getByTestId('migration-unavailable')).toContainText(
			'Algolia migration is temporarily unavailable while we replace the importer.'
		);
		await expect(page.getByText(/temporarily turned off new search data imports/i)).toBeVisible();

		await expect(page.getByTestId('migration-available')).toHaveCount(0);
		await expect(page.getByTestId('migration-create-flow')).toHaveCount(0);
		await expect(page.getByTestId('migration-recent-imports')).toHaveCount(0);
		await expect(page.getByLabel('Algolia Application ID')).toHaveCount(0);
		await expect(page.getByLabel('Algolia API key')).toHaveCount(0);
		await expect(page.getByRole('button', { name: 'Connect to Algolia' })).toHaveCount(0);
		await expect(page.getByRole('button', { name: 'Check destination eligibility' })).toHaveCount(
			0
		);
		await expect(page.getByRole('button', { name: 'Start import' })).toHaveCount(0);
	});
});
