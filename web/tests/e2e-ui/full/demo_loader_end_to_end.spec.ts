import { test, expect } from '../../fixtures/fixtures';
import { chooseFirstAvailableRegion } from '../../fixtures/create_index_form_helpers';
import {
	SEARCH_PANEL_TEST_ID,
	SEARCH_TAB_LABEL,
	SEARCH_TAB_QUERY_VALUE,
	startSearchPreviewSearchCapture,
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
			await completeFreshSignupEmailVerification(page, email, password);
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
			new RegExp(`/console/indexes/${encodeURIComponent(createdIndexName)}$`),
			{ timeout: 90_000 }
		);
		await page.getByRole('tab', { name: 'Settings' }).click();
		await page.getByRole('tab', { name: 'Advanced JSON' }).click();
		const settings = JSON.parse(await page.getByLabel('Settings JSON').inputValue()) as {
			attributesForFaceting?: string[];
		};
		expect(settings.attributesForFaceting).toEqual(['genre', 'director', 'year']);

		const searchCapture = startSearchPreviewSearchCapture(page);
		await page.getByRole('tab', { name: SEARCH_TAB_LABEL }).click();
		const searchUrl = new URL(page.url());
		expect(searchUrl.searchParams.get('tab')).toBe(SEARCH_TAB_QUERY_VALUE);

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

		await page.getByRole('tab', { name: SEARCH_TAB_LABEL }).click();
		await expect(page.getByTestId(SEARCH_PANEL_TEST_ID)).toBeVisible({ timeout: 10_000 });
		await waitForSearchPreviewReady(page);
		expect(searchCapture.payloads).toHaveLength(0);
		await submitSearchPreviewQuery(page, 'The Dark Knight');
		await waitForSearchPreviewHitsToContain(page, 'The Dark Knight', 60_000);
		expect(searchCapture.payloads).toHaveLength(1);
		searchCapture.stop();
		for (const facet of ['genre', 'director', 'year']) {
			await expect(page.getByTestId(`facet-panel-${facet}`)).toBeVisible();
		}
		for (const [testId, label] of [
			['facet-value-genre-Action', 'Action'],
			['facet-value-genre-Crime', 'Crime'],
			['facet-value-genre-Drama', 'Drama'],
			['facet-value-director-Christopher Nolan', 'Christopher Nolan'],
			['facet-value-year-2008', '2008']
		] as const) {
			await expect(page.getByTestId(testId)).toContainText(label);
			await expect(page.getByTestId(testId)).toContainText('1');
		}
		await page.getByLabel('genre:Action').check();
		await expect(page.getByTestId('document-card')).toHaveCount(1, { timeout: 30_000 });
		await expect(page.getByTestId('document-card')).toContainText('movie_3');
		const highlight = page.getByTestId('search-highlight').first();
		await expect(highlight).toHaveCSS('font-weight', '700');
		await expect(highlight).toHaveCSS('background-color', 'rgb(246, 193, 91)');
		await expect(highlight).toHaveCSS('font-style', 'normal');
		await expect(
			page
				.getByTestId('search-preview-results')
				.getByRole('button', { name: 'Open details' })
				.first()
		).toBeVisible({ timeout: 60_000 });
		await expect(page.getByTestId('instantsearch-widget')).toBeVisible();
		await expect(page.getByTestId(SEARCH_PANEL_TEST_ID)).toBeVisible();
	});
});
