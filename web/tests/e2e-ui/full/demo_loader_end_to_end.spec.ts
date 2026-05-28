import { test, expect } from '../../fixtures/fixtures';
import { chooseFirstAvailableRegion } from '../../fixtures/create_index_form_helpers';
import {
	generatePreviewKeyAndWaitForWidget,
	submitSearchPreviewQuery,
	waitForSearchPreviewHitsToContain,
	waitForSearchPreviewReady
} from '../../fixtures/search-preview-helpers';

test.describe('Demo loader end-to-end', () => {
	test('create dialog seeds demo dataset and search preview renders hits', async ({
		page,
		registerIndexForCleanup,
		createUser,
		setBillingPlanForCustomer,
		completeFreshSignupEmailVerification,
		isFreshSignupArrangePrerequisiteFailure
	}) => {
		test.setTimeout(180_000);
		const seed = Date.now();
		const email = `demo-loader-${seed}@e2e.griddle.test`;
		const password = 'TestPassword123!';
		const createdIndexName = `e2e-demo-loader-${seed}`;
		const deterministicHitTitle = `Demo Loader Deterministic Hit ${seed}`;

		const adminKey = process.env.E2E_ADMIN_KEY ?? process.env.ADMIN_KEY;
		if (!adminKey?.trim()) {
			test.skip(true, 'E2E_ADMIN_KEY required for demo-loader end-to-end flow');
			return;
		}

		await page.context().clearCookies();
		try {
			const createdUser = await createUser(email, password, `Demo Loader ${seed}`);
			// Shared plan now enforces billing-setup completion; keep demo-loader
			// coverage on free plan to avoid unrelated billing-gate failures.
			await setBillingPlanForCustomer(createdUser.customerId, 'free');
			await completeFreshSignupEmailVerification(page, email);
		} catch (error) {
			const failureMessage = error instanceof Error ? error.message : String(error);
			if (isFreshSignupArrangePrerequisiteFailure(failureMessage)) {
				test.skip(true, `demo-loader e2e prerequisite unavailable in local env: ${failureMessage}`);
				return;
			}
			throw error;
		}

		await page.goto('/login');
		await page.getByLabel('Email').fill(email);
		await page.getByLabel('Password').fill(password);
		await page.getByRole('button', { name: 'Log In' }).click();
		await expect(page).toHaveURL(/\/console/, { timeout: 10_000 });

		await page.goto('/console/indexes');
		await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();
		await page.getByRole('button', { name: 'Create Index' }).click();

		const createForm = page.getByTestId('create-index-form');
		await expect(createForm).toBeVisible();
		await createForm.getByText('Movies — 1,000 docs', { exact: true }).click();
		await createForm.getByLabel('Index name').fill(createdIndexName);
		await chooseFirstAvailableRegion(page);
		await page.getByRole('button', { name: 'Create', exact: true }).click();
		registerIndexForCleanup(createdIndexName);

		await expect(page).toHaveURL(
			new RegExp(`/console/indexes/${encodeURIComponent(createdIndexName)}\\?welcome=1`),
			{ timeout: 90_000 }
		);

		await page.getByRole('button', { name: 'Open Search Preview' }).click();
		await expect(page).toHaveURL(/welcome=0/, { timeout: 5_000 });
		await expect(page).toHaveURL(/tab=search-preview/, { timeout: 5_000 });

		await page.getByRole('tab', { name: 'Documents' }).click();
		await expect(page.getByTestId('documents-section')).toBeVisible({ timeout: 10_000 });
		await page.getByLabel('Record JSON').fill(
			JSON.stringify({
				objectID: `demo-loader-doc-${seed}`,
				title: deterministicHitTitle,
				body: 'demo loader deterministic document'
			})
		);
		await page.getByRole('button', { name: 'Add Record' }).click();
		await expect(page.getByText('Document added.')).toBeVisible({ timeout: 15_000 });

		await page.getByRole('tab', { name: 'Search Preview' }).click();
		await expect(page.getByTestId('search-preview-section')).toBeVisible({ timeout: 10_000 });
		await waitForSearchPreviewReady(page);
		await generatePreviewKeyAndWaitForWidget(page);
		await submitSearchPreviewQuery(page, deterministicHitTitle);
		await waitForSearchPreviewHitsToContain(page, deterministicHitTitle, 60_000);
		await expect(
			page.getByTestId('search-preview-results').getByRole('button', { name: /^Open hit / }).first()
		).toBeVisible({ timeout: 60_000 });
		await expect(page.getByTestId('instantsearch-widget')).toBeVisible();
		await expect(page.getByTestId('search-preview-section')).toBeVisible();
	});
});
