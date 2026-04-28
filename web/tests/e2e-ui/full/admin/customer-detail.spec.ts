import type { Locator, Page } from '@playwright/test';
import { test, expect } from '../../../fixtures/fixtures';

type CreatedCustomer = {
	customerId: string;
	token: string;
	email: string;
	password: string;
};
type CreateUserFn = (
	customerEmail: string,
	password: string,
	customerName: string
) => Promise<CreatedCustomer>;
type SeedCustomerIndexFn = (
	customer: CreatedCustomer,
	name: string,
	region?: string
) => Promise<void>;

const TEST_PASSWORD = 'TestPassword123!';

async function gotoCustomerDetail(
	page: Page,
	customerId: string,
	customerName: string
): Promise<void> {
	await page.goto(`/admin/customers/${customerId}`);
	await expect(page).toHaveURL(new RegExp(`/admin/customers/${customerId}$`), {
		timeout: 15_000
	});
	await expect(page.getByRole('heading', { name: customerName })).toBeVisible({ timeout: 15_000 });
	await expect(page.getByTestId('customer-status')).toBeVisible({ timeout: 5_000 });
}

async function openCustomerListWithSearch(
	page: Page,
	customerName: string
): Promise<{
	customersTableBody: Locator;
	filteredRows: Locator;
}> {
	await page.goto('/admin/customers');
	await expect(page.getByRole('heading', { name: 'Customer Management' })).toBeVisible();
	await page.getByTestId('customer-search').fill(customerName);

	const customersTableBody = page.getByTestId('customers-table-body');
	const filteredRows = customersTableBody.getByRole('row');
	await expect(filteredRows).toHaveCount(1, { timeout: 15_000 });

	return { customersTableBody, filteredRows };
}

async function openCustomerFromList(page: Page, customerName: string): Promise<void> {
	const { customersTableBody } = await openCustomerListWithSearch(page, customerName);

	const detailLink = customersTableBody.getByRole('link', { name: customerName }).first();
	await expect(detailLink).toHaveAttribute('href', /\/admin\/customers\/[^/]+$/);
	await detailLink.click();
	await expect(page).toHaveURL(/\/admin\/customers\/[^/]+$/, { timeout: 15_000 });
	await expect(page.getByRole('heading', { name: customerName })).toBeVisible({ timeout: 15_000 });
	await expect(page.getByTestId('customer-status')).toBeVisible({ timeout: 5_000 });
}

async function waitForCustomerInList(page: Page, customerName: string): Promise<void> {
	const { customersTableBody } = await openCustomerListWithSearch(page, customerName);
	await expect(customersTableBody.getByRole('link', { name: customerName })).toHaveCount(1);
}

async function createAdminCustomer(
	createUser: CreateUserFn,
	customerNamePrefix: string,
	customerEmailPrefix: string
): Promise<{ customer: CreatedCustomer; customerEmail: string; customerName: string }> {
	const seed = Date.now();
	const customerName = `${customerNamePrefix} ${seed}`;
	const customerEmail = `${customerEmailPrefix}-${seed}@e2e.griddle.test`;
	const customer = await createUser(customerEmail, TEST_PASSWORD, customerName);

	return { customer, customerEmail, customerName };
}

async function updateQuotaWithRetry(page: Page, value: string): Promise<void> {
	await expect(async () => {
		await page.getByRole('button', { name: 'Quotas', exact: true }).click();
		await expect(page.getByTestId('update-quotas-form')).toBeVisible();
		await page.getByLabel('Max Query RPS').fill(value);
		await page.getByTestId('update-quotas-button').click();

		if (
			await page
				.getByText('Quotas updated')
				.isVisible()
				.catch(() => false)
		) {
			return;
		}

		if (
			await page
				.getByText('too many requests')
				.isVisible()
				.catch(() => false)
		) {
			throw new Error('Quota update was transiently rate-limited; retrying through visible UI');
		}

		await expect(page.getByText('Quotas updated')).toBeVisible({ timeout: 10_000 });
	}).toPass({
		intervals: [1_000, 2_000, 3_000, 4_000],
		timeout: 30_000
	});
}

async function expectQuotaRowQueryRps(
	page: Page,
	indexName: string,
	expectedQueryRps: string
): Promise<void> {
	const quotaRow = page.getByRole('row').filter({ hasText: indexName });
	await expect(quotaRow).toHaveCount(1);
	// The success banner alone can be a false positive: the quota must be visible
	// on the exact seeded index row that this test arranged for the customer.
	await expect(quotaRow.getByRole('cell', { name: expectedQueryRps, exact: true })).toBeVisible();
}

async function expectDeploymentPanelWithoutRecords(page: Page): Promise<void> {
	await expect(
		page
			.getByText('Deployment data unavailable.')
			.or(page.getByText('No deployments found for this customer.'))
	).toBeVisible();
}

async function expectQuotaPanelWithoutIndexes(page: Page): Promise<void> {
	await expect(
		page
			.getByText('No indexes found for this customer.')
			.or(page.getByText('Quota data unavailable.'))
	).toBeVisible();
}

async function expectUsagePanelLoaded(page: Page): Promise<void> {
	const searchesCard = page.getByText('Searches');
	if (await searchesCard.isVisible().catch(() => false)) {
		await expect(page.getByText('0.00')).toBeVisible();
		return;
	}

	await expect(page.getByText('Usage data unavailable.')).toBeVisible();
}

test.describe('Admin customer detail workflows', () => {
	test.describe.configure({ timeout: 120_000 });

	test('customer list drill-down renders detail identity and all tab buttons', async ({
		page,
		createUser
	}) => {
		const { customerEmail, customerName } = await createAdminCustomer(
			createUser,
			'Admin Detail Customer',
			'admin-detail'
		);

		await openCustomerFromList(page, customerName);
		await expect(page.getByRole('definition').filter({ hasText: customerEmail })).toBeVisible();
		await expect(page.getByTestId('customer-status')).toBeVisible();

		await expect(page.getByRole('button', { name: 'Info' })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Indexes' })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Deployments' })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Usage' })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Invoices' })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Rate Card' })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Quotas' })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Audit' })).toBeVisible();
	});

	test('customer detail tabs lazy-mount on click and render panel content', async ({
		page,
		createUser
	}) => {
		const { customerEmail, customerName } = await createAdminCustomer(
			createUser,
			'Admin Tabs Customer',
			'admin-tabs'
		);

		await openCustomerFromList(page, customerName);

		await expect(page.getByRole('heading', { name: 'Customer Info' })).toBeVisible();
		const infoDefinitions = page.getByRole('definition');
		await expect(infoDefinitions.filter({ hasText: customerName })).toHaveCount(1);
		await expect(infoDefinitions.filter({ hasText: customerEmail })).toHaveCount(1);
		await expect(infoDefinitions.filter({ hasText: /^active$/i })).toHaveCount(1);

		const indexesHeading = page.getByRole('heading', { name: 'Indexes' });
		await expect(indexesHeading).toHaveCount(0);
		await page.getByRole('button', { name: 'Indexes' }).click();
		await expect(page.getByText('Index data unavailable.')).toBeVisible();

		const deploymentsHeading = page.getByRole('heading', { name: 'Deployments' });
		await expect(deploymentsHeading).toHaveCount(0);
		await page.getByRole('button', { name: 'Deployments' }).click();
		await expectDeploymentPanelWithoutRecords(page);

		const usageHeading = page.getByRole('heading', { name: 'Usage' });
		await expect(usageHeading).toHaveCount(0);
		await page.getByRole('button', { name: 'Usage' }).click();
		await expectUsagePanelLoaded(page);

		const invoicesHeading = page.getByRole('heading', { name: 'Invoices' });
		await expect(invoicesHeading).toHaveCount(0);
		await page.getByRole('button', { name: 'Invoices' }).click();
		await expect(page.getByText('No invoices found for this customer.')).toBeVisible();

		const rateCardHeading = page.getByRole('heading', { name: 'Rate Card' });
		await expect(rateCardHeading).toHaveCount(0);
		await page.getByRole('button', { name: 'Rate Card' }).click();
		await expect(page.getByRole('heading', { name: 'Rate Card' })).toBeVisible();
		// Every customer gets the active base rate card; verify it renders real content
		await expect(page.getByText('Storage per MB / month')).toBeVisible();

		const quotasHeading = page.getByRole('heading', { name: 'Index Quotas' });
		await expect(quotasHeading).toHaveCount(0);
		await page.getByRole('button', { name: 'Quotas' }).click();
		await expectQuotaPanelWithoutIndexes(page);

		const auditHeading = page.getByRole('heading', { name: 'Audit Timeline' });
		await expect(auditHeading).toHaveCount(0);
		await page.getByRole('button', { name: 'Audit' }).click();
		await expect(page.getByText('No audit events recorded for this customer yet.')).toBeVisible();
	});

	test('quota update form submits and shows success feedback', async ({
		page,
		createUser,
		seedCustomerIndex
	}) => {
		const { customer, customerName } = await createAdminCustomer(
			createUser,
			'Admin Quota Target',
			'admin-quota'
		);
		const indexName = `admin-quota-index-${Date.now()}`;
		const updatedQueryRps = '743';
		await seedCustomerIndex(customer, indexName);

		await gotoCustomerDetail(page, customer.customerId, customerName);

		await page.getByRole('button', { name: 'Quotas' }).click();
		await expect(page.getByTestId('update-quotas-form')).toBeVisible();
		await expect(page.getByTestId('update-quotas-button')).toBeVisible();
		await expect(page.getByRole('row').filter({ hasText: indexName })).toHaveCount(1);

		await updateQuotaWithRetry(page, updatedQueryRps);
		await expectQuotaRowQueryRps(page, indexName, updatedQueryRps);
	});

	test('deployment tab shows empty state when no deployments exist', async ({
		page,
		createUser
	}) => {
		// NOTE: Fresh users have no deployments. This test verifies the empty state
		// and records that deployment termination is blocked on seeded deployment data.
		const { customer, customerName } = await createAdminCustomer(
			createUser,
			'Admin Deploy Target',
			'admin-deploy'
		);

		await gotoCustomerDetail(page, customer.customerId, customerName);

		await page.getByRole('button', { name: 'Deployments' }).click();
		// Fresh user has no deployments — terminate button should not exist
		await expectDeploymentPanelWithoutRecords(page);
		await expect(page.getByTestId('terminate-deployment-button')).toHaveCount(0);
	});

	test('customer list search and active-status filter narrow visible rows', async ({
		page,
		createUser
	}) => {
		const { customerName: searchName } = await createAdminCustomer(
			createUser,
			'Admin Search Target',
			'admin-search'
		);

		await waitForCustomerInList(page, searchName);

		const filteredRows = page.getByTestId('customers-table-body').getByRole('row');
		await expect(filteredRows).toHaveCount(1);
		await expect(page.getByRole('link', { name: searchName })).toBeVisible();

		await page.getByTestId('customer-search').fill('');
		await page.getByTestId('status-filter').selectOption('active');

		const activeRows = page.getByTestId('customers-table-body').getByRole('row');
		const activeCount = await activeRows.count();
		expect(activeCount).toBeGreaterThan(0);

		for (let i = 0; i < activeCount; i += 1) {
			await expect(activeRows.nth(i).getByText(/^active$/i)).toBeVisible();
		}
	});

	test('customer detail soft delete redirects to the list and excludes the customer from active rows', async ({
		page,
		createUser
	}) => {
		const { customer, customerName } = await createAdminCustomer(
			createUser,
			'Admin Delete Target',
			'admin-delete'
		);
		await gotoCustomerDetail(page, customer.customerId, customerName);

		await page.getByRole('button', { name: 'Soft Delete' }).click();
		await expect(page).toHaveURL(/\/admin\/customers$/);
		await expect(page.getByRole('heading', { name: 'Customer Management' })).toBeVisible();

		await page.getByTestId('customer-search').fill(customerName);
		await expect(page.getByRole('link', { name: customerName })).toBeVisible({ timeout: 10_000 });

		const filteredRows = page.getByTestId('customers-table-body').getByRole('row');
		await expect(filteredRows).toHaveCount(1);
		await expect(filteredRows.first().getByRole('link', { name: customerName })).toBeVisible();
		await expect(filteredRows.first().getByText(/^deleted$/i)).toBeVisible();

		await page.getByTestId('status-filter').selectOption('deleted');
		await expect(filteredRows).toHaveCount(1);
		await expect(filteredRows.first().getByText(/^deleted$/i)).toBeVisible();

		await page.getByTestId('status-filter').selectOption('active');
		await expect(filteredRows).toHaveCount(0);
		await expect(page.getByText('No customers match the current filters.')).toBeVisible();
	});

	test('admin suspend to reactivate lifecycle updates status-gated controls', async ({
		page,
		createUser
	}) => {
		const { customer, customerName } = await createAdminCustomer(
			createUser,
			'Admin Suspend Target',
			'admin-suspend'
		);

		await gotoCustomerDetail(page, customer.customerId, customerName);

		const statusBadge = page.getByTestId('customer-status');
		await expect(statusBadge).toHaveText(/active/i);
		await expect(page.getByTestId('suspend-button')).toBeVisible();
		await expect(page.getByTestId('reactivate-button')).toHaveCount(0);

		await page.getByTestId('suspend-button').click();
		await expect(statusBadge).toHaveText(/suspended/i, { timeout: 10_000 });
		await expect(page.getByTestId('reactivate-button')).toBeVisible();
		await expect(page.getByTestId('suspend-button')).toHaveCount(0);

		await page.getByTestId('reactivate-button').click();
		await expect(statusBadge).toHaveText(/active/i, { timeout: 10_000 });
		await expect(page.getByTestId('suspend-button')).toBeVisible();
		await expect(page.getByTestId('reactivate-button')).toHaveCount(0);
	});

	test('admin customer impersonation flow returns to the same detail page', async ({
		page,
		createUser
	}) => {
		const { customer, customerName } = await createAdminCustomer(
			createUser,
			'Admin Impersonation Target',
			'admin-impersonation'
		);

		await gotoCustomerDetail(page, customer.customerId, customerName);

		await page.getByTestId('impersonate-button').click();

		await expect(page).toHaveURL(/\/dashboard/, { timeout: 10_000 });
		await expect(page.getByTestId('impersonation-banner')).toBeVisible();
		await expect(page.getByText('You are impersonating this customer.')).toBeVisible();

		await page.getByTestId('end-impersonation-button').click();
		await expect(page).toHaveURL(new RegExp(`/admin/customers/${customer.customerId}$`), {
			timeout: 10_000
		});
	});

	// -----------------------------------------------------------------------
	// Stage 2 red baseline: deterministic readiness tests for the shared helper
	// path. These assert the contract the broader customer-detail slice also uses.
	// -----------------------------------------------------------------------

	test('deterministic: detail page renders heading and status without sleep retries', async ({
		page,
		createUser
	}) => {
		const { customer, customerEmail, customerName } = await createAdminCustomer(
			createUser,
			'Deterministic Detail',
			'det-detail'
		);

		await gotoCustomerDetail(page, customer.customerId, customerName);
		await expect(page.getByRole('definition').filter({ hasText: customerEmail })).toBeVisible();
		await expect(page.getByTestId('customer-status')).toBeVisible();
	});

	test('deterministic: customer list drill-down finds row via locator expectation, not sleep loop', async ({
		page,
		createUser
	}) => {
		const { customerEmail, customerName } = await createAdminCustomer(
			createUser,
			'Deterministic List',
			'det-list'
		);

		await openCustomerFromList(page, customerName);
		await expect(page.getByRole('definition').filter({ hasText: customerEmail })).toBeVisible();
		await expect(page.getByTestId('customer-status')).toBeVisible();
	});

	test('deterministic: waitForCustomerInList finds filtered row via locator expectation', async ({
		page,
		createUser
	}) => {
		const { customerName } = await createAdminCustomer(
			createUser,
			'Deterministic Search',
			'det-search'
		);

		await waitForCustomerInList(page, customerName);
		const filteredRows = page.getByTestId('customers-table-body').getByRole('row');
		await expect(filteredRows).toHaveCount(1);
		await expect(page.getByRole('link', { name: customerName })).toBeVisible();
	});
});
