import { chooseFirstAvailableRegion } from '../../fixtures/create_index_form_helpers';
import { test, expect } from '../../fixtures/fixtures';
import { SEARCH_TAB_LABEL, SEARCH_TAB_QUERY_VALUE } from '../../fixtures/search-preview-helpers';

test.describe('Create index dialog completion flow', () => {
	test('create submit redirects to detail without a redundant welcome banner', async ({
		page,
		registerIndexForCleanup,
		createUser,
		setBillingPlanForCustomer,
		completeFreshSignupEmailVerification,
		isFreshSignupArrangePrerequisiteFailure
	}) => {
		test.setTimeout(60_000);
		const seed = Date.now();
		const email = `indexes-create-completion-${seed}@e2e.griddle.test`;
		const password = 'TestPassword123!';
		const createdIndexName = `e2e-create-${seed}`;

		const adminKey = process.env.E2E_ADMIN_KEY ?? process.env.ADMIN_KEY;
		if (!adminKey?.trim()) {
			test.skip(true, 'E2E_ADMIN_KEY required for fresh-signup create->welcome flow');
			return;
		}

		await page.context().clearCookies();
		try {
			const createdUser = await createUser(email, password, `Indexes Create Completion ${seed}`);
			// Shared plan now enforces billing-setup completion; keep this flow on
			// free plan so create-index redirect coverage is isolated to index UX.
			await setBillingPlanForCustomer(createdUser.customerId, 'free');
			await completeFreshSignupEmailVerification(page, email, password);
		} catch (error) {
			const failureMessage = error instanceof Error ? error.message : String(error);
			if (isFreshSignupArrangePrerequisiteFailure(failureMessage)) {
				test.skip(
					true,
					`create completion e2e prerequisite unavailable in local env: ${failureMessage}`
				);
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
			new RegExp(`/console/indexes/${encodeURIComponent(createdIndexName)}$`)
		);

		const redirectedUrl = new URL(page.url());
		expect(redirectedUrl.pathname).toBe(`/console/indexes/${createdIndexName}`);
		expect(redirectedUrl.search).toBe('');

		await expect(page.getByText('Index ready — try Search', { exact: true })).toHaveCount(0);
		await expect(page.getByRole('button', { name: 'Open Search' })).toHaveCount(0);

		const probeUrl = new URL(page.url());
		probeUrl.searchParams.set('source', 'e2e');
		await page.goto(probeUrl.toString());
		await page.getByRole('tab', { name: SEARCH_TAB_LABEL }).click();

		const consumedUrl = new URL(page.url());
		expect(consumedUrl.pathname).toBe(`/console/indexes/${createdIndexName}`);
		expect(consumedUrl.searchParams.get('tab')).toBe(SEARCH_TAB_QUERY_VALUE);
		expect(consumedUrl.searchParams.get('source')).toBe('e2e');
	});
});
