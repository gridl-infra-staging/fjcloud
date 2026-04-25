/**
 * Full — Customer Journeys (fresh user)
 *
 * End-to-end continuity check for a brand-new customer: starts from the
 * dashboard onboarding banner, completes the onboarding wizard to create
 * an index and obtain credentials, adds a document through the Documents
 * tab, and verifies a real search hit through the Search Preview tab.
 *
 * Uses the chromium:customer-journeys project with its own freshly signed-up
 * account so this long-form flow does not consume the same storage state that
 * onboarding.spec.ts depends on.
 *
 * Cleanup: deletes the onboarding-created index so the shared fresh-user
 * account still shows the onboarding banner for sibling specs.
 */

import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import {
	gotoIndexDetailWithRetry,
	submitSearchPreviewQuery,
	waitForSearchPreviewReady
} from '../../fixtures/search-preview-helpers';

// ---------------------------------------------------------------------------
// Spec-local helpers
// ---------------------------------------------------------------------------

/**
 * Delete the onboarding-created index and verify the onboarding banner
 * reappears on the dashboard. This keeps reruns idempotent inside the
 * customer-journeys lane itself.
 *
 * The shared fixtures.ts page fixture already auto-accepts native
 * confirm() dialogs (fixtures.ts:300), so no manual dialog handler is
 * needed here.
 */
async function cleanupOnboardingIndex(
	page: Page,
	indexName: string,
	cleanupRequired: boolean
): Promise<void> {
	if (!cleanupRequired) {
		return;
	}

	await page.goto('/dashboard/indexes');

	const createdRow = page.getByRole('row').filter({
		has: page.getByRole('link', { name: indexName })
	});
	const deleteButton = createdRow.getByRole('button', { name: 'Delete' });

	await expect(deleteButton).toBeVisible({ timeout: 30_000 });
	await deleteButton.click();

	// Wait for the row to disappear after the auto-accepted confirm dialog
	await expect(page.getByRole('cell', { name: indexName })).toHaveCount(0, { timeout: 30_000 });

	// Verify the onboarding banner is restored for sibling specs
	await page.goto('/dashboard');
	await expect(page.getByTestId('onboarding-banner')).toBeVisible({ timeout: 30_000 });
}

// ---------------------------------------------------------------------------
// Journey spec
// ---------------------------------------------------------------------------

test.describe('Fresh-user customer journey — onboard to first search hit', () => {
	// Shared account, no retries — a retry would see stale wizard state
	test.describe.configure({ retries: 0 });

	test('onboard, add document, search, cleanup', async ({ page }) => {
		// Full journey can take 2+ minutes on shared-VM stacks due to index
		// provisioning and credential generation.
		test.setTimeout(180_000);

		const indexName = `journey-${Date.now()}`;
		let cleanupRequired = false;

		try {
			// ---------------------------------------------------------------
			// Step 1: Dashboard — assert onboarding banner and navigate
			// ---------------------------------------------------------------
			await page.goto('/dashboard');
			await expect(page.getByTestId('onboarding-banner')).toBeVisible({ timeout: 10_000 });
			await expect(
				page.getByTestId('onboarding-banner').getByText('Complete your setup')
			).toBeVisible();

			// ACT: click the banner link to enter the onboarding wizard
			await page
				.getByTestId('onboarding-banner')
				.getByRole('link', { name: 'Continue setup' })
				.click();

			// ---------------------------------------------------------------
			// Step 2: Onboarding step 1 — fill index name and submit
			// ---------------------------------------------------------------
			await expect(page).toHaveURL(/\/dashboard\/onboarding/);
			await expect(page.getByTestId('onboarding-step-1')).toBeVisible();

			const nameInput = page.getByLabel('Index name');
			await expect(nameInput).toBeVisible();
			await nameInput.clear();
			await nameInput.fill(indexName);

			// ACT: submit the form to create the index
			await page.getByRole('button', { name: 'Continue' }).click();

			// ---------------------------------------------------------------
			// Step 3: Wait through preparing/generating intermediate states
			// ---------------------------------------------------------------
			// The wizard may pass through 'preparing' (step-2) with auto-polling,
			// then reach 'generating' (step-3) where credentials can be fetched.
			// Wait for step-3 to appear — this covers both direct and multi-step
			// transitions.
			await expect(page.getByTestId('onboarding-step-3')).toBeVisible({ timeout: 90_000 });

			// Reaching step 3 means the onboarding-created index now exists, so
			// any later failure must still tear it down for sibling specs.
			cleanupRequired = true;

			// ---------------------------------------------------------------
			// Step 4: Navigate to index detail page
			// ---------------------------------------------------------------
			// Reaching step 3 proves the onboarding wizard accepted the index
			// creation flow and handed off to the post-create phase. Dedicated
			// onboarding tests cover the one-time credentials surface itself; this
			// continuity spec continues into the real index workflow.
			await gotoIndexDetailWithRetry(page, indexName);

			// ---------------------------------------------------------------
			// Step 5: Documents tab — add one document through the UI
			// ---------------------------------------------------------------
			// ACT: switch to the Documents tab via the visible tab bar
			await page.getByRole('tab', { name: 'Documents' }).click();
			await expect(page.getByTestId('documents-section')).toBeVisible({ timeout: 10_000 });

			// ACT: fill the "Add Manually" form with a known JSON document
			const docJson = JSON.stringify({
				objectID: 'journey-doc-1',
				title: 'Journey Test Document',
				body: 'search test content for first customer journey'
			});

			await page.getByLabel('Record JSON').fill(docJson);
			await page.getByRole('button', { name: 'Add Record' }).click();

			// ASSERT: success feedback appears
			await expect(page.getByText('Document added.')).toBeVisible({ timeout: 15_000 });

			// ---------------------------------------------------------------
			// Step 6: Search Preview tab — verify a real search hit
			// ---------------------------------------------------------------
			// ACT: switch to the Search Preview tab
			await page.getByRole('tab', { name: 'Search Preview' }).click();
			await expect(page.getByTestId('search-preview-section')).toBeVisible({ timeout: 10_000 });

			// Wait until the preview can actually generate a key for this
			// onboarding-created index. A timeout here is a real failure for the
			// continuity path, not a skip condition.
			await waitForSearchPreviewReady(page);

			// ACT: generate a preview key
			await page
				.getByTestId('search-preview-section')
				.getByRole('button', { name: /generate preview key/i })
				.click();
			await expect(page.getByTestId('instantsearch-widget')).toBeVisible({ timeout: 30_000 });

			// ACT: type a query into the search box
			// instantsearch.js renders a real <input> inside the searchbox container
			await submitSearchPreviewQuery(page, 'Journey');

			// ASSERT: the inserted document appears in the hits
			// Search indexing may have latency; poll for the hit to appear
			await expect
				.poll(
					async () => {
						const hitsText = await page.getByTestId('instantsearch-hits').textContent();
						return hitsText;
					},
					{ timeout: 30_000, message: 'Waiting for search hit to contain "Journey Test Document"' }
				)
				.toContain('Journey Test Document');
		} finally {
			// ---------------------------------------------------------------
			// Step 7: Cleanup — delete index and restore onboarding banner
			// ---------------------------------------------------------------
			await cleanupOnboardingIndex(page, indexName, cleanupRequired);
		}
	});
});
