import { chooseFirstAvailableRegion } from '../../fixtures/create_index_form_helpers';
import { test, expect } from '../../fixtures/fixtures';

test.describe('Create index dialog welcome flow', () => {
	test('create submit redirects to welcome banner and CTA consumes welcome param', async ({
		page,
		registerIndexForCleanup,
		createUser,
		completeFreshSignupEmailVerification,
		isFreshSignupArrangePrerequisiteFailure
	}) => {
		test.setTimeout(60_000);
		const seed = Date.now();
		const email = `indexes-create-welcome-${seed}@e2e.griddle.test`;
		const password = 'TestPassword123!';
		const createdIndexName = `e2e-create-${seed}`;

		const adminKey = process.env.E2E_ADMIN_KEY ?? process.env.ADMIN_KEY;
		if (!adminKey?.trim()) {
			test.skip(true, 'E2E_ADMIN_KEY required for fresh-signup create->welcome flow');
			return;
		}

		await page.context().clearCookies();
		try {
			await createUser(email, password, `Indexes Create Welcome ${seed}`);
			await completeFreshSignupEmailVerification(page, email);
		} catch (error) {
			const failureMessage = error instanceof Error ? error.message : String(error);
			if (isFreshSignupArrangePrerequisiteFailure(failureMessage)) {
				test.skip(
					true,
					`create->welcome e2e prerequisite unavailable in local env: ${failureMessage}`
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
			new RegExp(`/console/indexes/${encodeURIComponent(createdIndexName)}\\?welcome=1`)
		);

		const redirectedUrl = new URL(page.url());
		expect(redirectedUrl.pathname).toBe(`/console/indexes/${createdIndexName}`);
		expect(redirectedUrl.searchParams.get('welcome')).toBe('1');

		await expect(
			page.getByText('Index ready — try the search preview', { exact: true })
		).toBeVisible();
		await expect(page.getByRole('button', { name: 'Open Search Preview' })).toBeVisible();

		const probeUrl = new URL(page.url());
		probeUrl.searchParams.set('source', 'e2e');
		await page.goto(probeUrl.toString());
		await expect(page.getByRole('button', { name: 'Open Search Preview' })).toBeVisible();

		await page.getByRole('button', { name: 'Open Search Preview' }).click();

		await expect(page).toHaveURL(/welcome=0/, { timeout: 5_000 });
		const consumedUrl = new URL(page.url());
		expect(consumedUrl.pathname).toBe(`/console/indexes/${createdIndexName}`);
		expect(consumedUrl.searchParams.get('welcome')).toBe('0');
		expect(consumedUrl.searchParams.get('tab')).toBe('search-preview');
		expect(consumedUrl.searchParams.get('source')).toBe('e2e');
	});
});
