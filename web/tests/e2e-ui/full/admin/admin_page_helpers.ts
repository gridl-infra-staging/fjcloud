import { expect, type Locator, type Page } from '@playwright/test';

export async function navigateToAdminPage(
	page: Page,
	path: string,
	heading: string
): Promise<void> {
	await page.goto(path);
	await expect(page.getByRole('heading', { name: heading })).toBeVisible();
}

/** Wait until both admin billing invoice sections have rendered rows or empty states. */
export async function waitForBillingSectionsToResolve(page: Page): Promise<{
	failedRows: Locator;
	draftRows: Locator;
	failedEmptyState: Locator;
	draftEmptyState: Locator;
}> {
	const failedSection = page.getByTestId('failed-invoices-section');
	const draftSection = page.getByTestId('draft-invoices-section');
	const failedRows = page.getByTestId('failed-invoice-row');
	const draftRows = page.getByTestId('draft-invoice-row');
	const failedEmptyState = failedSection.getByText('No failed invoices.');
	const draftEmptyState = draftSection.getByText('No draft invoices awaiting finalization.');

	await expect
		.poll(async () => (await failedRows.count()) + (await failedEmptyState.count()), {
			message: 'failed invoice section should render either seeded rows or its empty state'
		})
		.toBeGreaterThan(0);
	await expect
		.poll(async () => (await draftRows.count()) + (await draftEmptyState.count()), {
			message: 'draft invoice section should render either seeded rows or its empty state'
		})
		.toBeGreaterThan(0);

	return { failedRows, draftRows, failedEmptyState, draftEmptyState };
}
