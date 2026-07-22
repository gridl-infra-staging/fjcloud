import { test, expect } from '../../fixtures/fixtures';

test('customer can inspect managed infrastructure and footprint at desktop and mobile widths', async ({
	page,
	arrangeTrackedCustomerSession,
	arrangeIndexInfrastructure
}) => {
	test.setTimeout(240_000);
	const customer = await arrangeTrackedCustomerSession(page, {
		emailPrefix: 'index-infrastructure'
	});
	const expected = await arrangeIndexInfrastructure(
		customer,
		`infrastructure-${Date.now()}`,
		'us-east-1',
		'eu-west-1'
	);

	await page.goto(`/console/indexes/${encodeURIComponent(expected.indexName)}`);
	const infrastructureTab = page.getByRole('tab', { name: 'Infrastructure', exact: true });
	await expect(infrastructureTab).toBeVisible();
	await infrastructureTab.click();
	await expect(infrastructureTab).toHaveAttribute('aria-selected', 'true');

	const panel = page.getByTestId('infrastructure-tab-panel');
	await expect(panel).toBeVisible();
	await expect(panel.getByRole('heading', { name: 'Infrastructure' })).toBeVisible();
	await expect(
		panel.getByText('Placement is automatically managed.', { exact: false })
	).toBeVisible();
	await expect(panel.getByText('read-only and informational', { exact: false })).toBeVisible();
	await expect(page.getByTestId('infrastructure-primary-row')).toContainText(
		`Primary · ${expected.primary.region}`
	);
	await expect(page.getByTestId('infrastructure-primary-row')).toContainText(
		expected.primary.status
	);
	await expect(page.getByTestId('infrastructure-primary-row')).toContainText(
		expected.primary.utilization
	);
	await expect(page.getByTestId('infrastructure-replica-row')).toContainText(
		`Replica · ${expected.replica.region}`
	);
	await expect(page.getByTestId('infrastructure-replica-row')).toContainText(
		expected.replica.status
	);
	await expect(page.getByTestId('infrastructure-replica-row')).toContainText(
		`${expected.replica.lagOperations} operations behind`
	);
	await expect(page.getByTestId('infrastructure-replica-row')).toContainText(
		expected.replica.utilization
	);
	await expect(page.getByTestId('infrastructure-headroom')).toHaveText(
		`Headroom: ${expected.headroom}`
	);
	await expect(page.getByTestId('infrastructure-failover')).toHaveText(expected.failover);
	await expect(page.getByTestId('infrastructure-footprint-documents')).toContainText(
		expected.footprint.documents
	);
	await expect(page.getByTestId('infrastructure-footprint-storage')).toContainText(
		expected.footprint.storage
	);
	await expect(page.getByTestId('infrastructure-footprint-search-requests')).toContainText(
		expected.footprint.searchRequests
	);
	await expect(page.getByTestId('infrastructure-footprint-write-operations')).toContainText(
		expected.footprint.writeOperations
	);
	for (const forbidden of expected.forbiddenText) {
		await expect(panel).not.toContainText(forbidden);
	}

	await page.getByRole('tab', { name: 'Metrics', exact: true }).click();
	await page.getByRole('link', { name: 'View infrastructure and headroom', exact: true }).click();
	await expect(infrastructureTab).toHaveAttribute('aria-selected', 'true');
	await expect(panel).toBeVisible();

	await page.setViewportSize({ width: 390, height: 844 });
	const mobileContractLocators = [
		panel.getByRole('heading', { name: 'Infrastructure' }),
		panel.getByRole('button', { name: 'Refresh' }),
		page.getByTestId('infrastructure-primary-row'),
		page.getByTestId('infrastructure-replica-row'),
		page.getByTestId('infrastructure-failover'),
		page.getByTestId('infrastructure-footprint-documents'),
		page.getByTestId('infrastructure-footprint-storage'),
		page.getByTestId('infrastructure-footprint-search-requests'),
		page.getByTestId('infrastructure-footprint-write-operations')
	];
	for (const locator of mobileContractLocators) {
		await expect(locator).toBeVisible();
		const box = await locator.boundingBox();
		expect(box).not.toBeNull();
		expect(box!.x).toBeGreaterThanOrEqual(0);
		expect(box!.x + box!.width).toBeLessThanOrEqual(390);
	}
});
