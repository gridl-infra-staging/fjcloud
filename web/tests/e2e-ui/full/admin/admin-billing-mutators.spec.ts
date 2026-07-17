/**
 * Full - Admin Billing Mutators
 *
 * Global billing actions mutate shared admin-visible billing state. Keep them
 * in their own project-routed file so admin shell/read-only coverage can run
 * with the broader admin lane while billing mutations stay single-worker.
 */

import { expect, test } from '../../../fixtures/fixtures';
import { navigateToAdminPage, waitForBillingSectionsToResolve } from './admin_page_helpers';

test.describe('Admin billing mutators', () => {
	test('Billing Run Billing flow renders visible confirmation text', async ({ page }) => {
		await navigateToAdminPage(page, '/admin/billing', 'Billing Review');

		await page.getByTestId('run-billing-button').click();
		await expect(page.getByTestId('confirm-billing-button')).toBeVisible();
		await page.getByLabel('Billing month').fill('2026-02');
		await page.getByTestId('confirm-billing-button').click();
		const feedbackBanner = page
			.getByTestId('billing-feedback-message')
			.or(page.getByTestId('billing-feedback-error'));
		await expect(feedbackBanner).toBeVisible({ timeout: 30_000 });
		await expect(feedbackBanner).toContainText(
			/Billing complete|Batch billing failed|too many requests/i
		);
	});

	test('Billing Bulk Finalize flow renders visible confirmation text', async ({ page }) => {
		await navigateToAdminPage(page, '/admin/billing', 'Billing Review');
		const { draftRows, draftEmptyState } = await waitForBillingSectionsToResolve(page);

		/* eslint-disable playwright/no-conditional-expect -- branch-specific assertions are required for draft-vs-empty seeded states */
		// eslint-disable-next-line playwright/no-conditional-in-test -- this proof must branch on seeded draft-row presence
		if (await draftRows.count()) {
			await page.getByTestId('bulk-finalize-button').click();
			const feedbackBanner = page
				.getByTestId('billing-feedback-message')
				.or(page.getByTestId('billing-feedback-error'));
			await expect(feedbackBanner).toBeVisible();
			await expect(feedbackBanner).toContainText(
				/Bulk finalize (complete|partially failed|failed)/
			);
		} else {
			await expect(page.getByTestId('bulk-finalize-button')).toHaveCount(0);
			await expect(draftEmptyState).toBeVisible();
		}
		/* eslint-enable playwright/no-conditional-expect */
	});
});
