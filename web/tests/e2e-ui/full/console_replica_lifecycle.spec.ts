import type { Response } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';

type ExpectedMutationResponse = 'json' | 'either';

async function expectSuccessfulMutationResponse(
	response: Response,
	actionName: string,
	expectedResponse: ExpectedMutationResponse
): Promise<void> {
	expect(response.ok(), `${actionName} should receive an HTTP-successful response`).toBe(true);

	const contentType = await response.headerValue('content-type');
	if (contentType?.includes('application/json')) {
		await expect(
			response.json(),
			`${actionName} should complete as a successful Svelte form action`
		).resolves.toMatchObject({
			type: 'success',
			status: 200
		});
		return;
	}

	if (contentType?.includes('text/html') && expectedResponse !== 'json') {
		return;
	}

	const expectedDescription = expectedResponse === 'either' ? 'JSON or HTML' : 'JSON';
	throw new Error(
		`${actionName} should return a successful ${expectedDescription} response, received content-type ${contentType ?? 'missing'}`
	);
}

test('row 16 @p0_coverage and row 17 @p0_coverage persist replica create and delete', async ({
	page,
	arrangeTrackedCustomerSession,
	seedCustomerIndex,
	ensureLocalSharedVmInventory,
	testRegion
}) => {
	test.setTimeout(180_000);
	const customer = await arrangeTrackedCustomerSession(page, {
		emailPrefix: 'console-replica-lifecycle'
	});
	const indexName = `console-replica-lifecycle-${Date.now()}`;

	await seedCustomerIndex(customer, indexName, testRegion);
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
	await expect(page.getByRole('heading', { name: indexName, exact: true })).toBeVisible();

	const replicasSection = page.getByTestId('replicas-section');
	await expect(replicasSection.getByRole('heading', { name: 'Read Replicas' })).toBeVisible();

	let selectedReplicaRegion = '';
	const replicaRow = () =>
		replicasSection.getByRole('row').filter({
			has: page.getByRole('cell', {
				name: selectedReplicaRegion,
				exact: true
			})
		});

	await test.step('create replica through rendered Add Replica controls', async () => {
		const addReplicaButton = replicasSection.getByRole('button', {
			name: 'Add Replica',
			exact: true
		});
		await expect(
			addReplicaButton,
			'Read Replicas is visible but Add Replica is unavailable. Diagnose /internal/regions authenticated-header propagation in the console page loader; smallest product fix: keep getInternalRegions authenticated instead of falling back to only the primary/default region.'
		).toHaveCount(1);

		await addReplicaButton.click();
		const targetRegionSelect = replicasSection.getByLabel('Target region', { exact: true });
		await expect(targetRegionSelect).toBeVisible();
		selectedReplicaRegion = await targetRegionSelect.evaluate((select, primaryRegion) => {
			const options = Array.from((select as HTMLSelectElement).options);
			const availableReplicaOption = options.find((option) => {
				const value = option.value.trim();
				return value.length > 0 && value !== primaryRegion;
			});
			return availableReplicaOption?.value.trim() ?? '';
		}, testRegion);

		expect(
			selectedReplicaRegion,
			'Read Replicas is visible but Target region has no non-primary option. Diagnose /internal/regions authenticated-header propagation in the console page loader; smallest product fix: preserve authenticated headers for /internal/regions so available replica regions render.'
		).not.toBe('');

		await ensureLocalSharedVmInventory(selectedReplicaRegion);
		await targetRegionSelect.selectOption(selectedReplicaRegion);
		const createReplicaResponsePromise = page.waitForResponse(
			(response) =>
				response.url().includes('?/createReplica') && response.request().method() === 'POST'
		);
		await replicasSection.getByRole('button', { name: 'Create', exact: true }).click();
		const createReplicaResponse = await createReplicaResponsePromise;
		await expectSuccessfulMutationResponse(createReplicaResponse, 'create replica', 'json');

		await expect(
			replicaRow(),
			`create step should render a row for replica region ${selectedReplicaRegion}`
		).toHaveCount(1);
		await expect(replicaRow().getByRole('cell').nth(1)).toHaveText(
			/^(Preparing|Syncing|Active|Failed)$/,
			{ timeout: 10_000 }
		);
		await expect(replicaRow().getByRole('cell').nth(2)).toHaveText(/^\d+$/);
	});

	await test.step('post-refresh persistence keeps the created replica row visible', async () => {
		await page.reload();
		await expect(replicasSection.getByRole('heading', { name: 'Read Replicas' })).toBeVisible();
		await expect(
			replicaRow(),
			`post-refresh persistence should keep replica region ${selectedReplicaRegion}`
		).toHaveCount(1);
		await expect(replicaRow().getByRole('cell').nth(1)).toHaveText(
			/^(Preparing|Syncing|Active|Failed)$/
		);
		await expect(replicaRow().getByRole('cell').nth(2)).toHaveText(/^\d+$/);
	});

	await test.step('delete replica through the exact row Remove control', async () => {
		page.removeAllListeners('dialog');
		page.once('dialog', async (dialog) => {
			expect(dialog.type()).toBe('confirm');
			expect(dialog.message()).toBe(`Remove read replica in ${selectedReplicaRegion}?`);
			await dialog.accept();
		});
		const deleteReplicaResponsePromise = page.waitForResponse(
			(response) =>
				response.url().includes('?/deleteReplica') && response.request().method() === 'POST'
		);
		await replicaRow().getByRole('button', { name: 'Remove', exact: true }).click();
		const deleteReplicaResponse = await deleteReplicaResponsePromise;
		await expectSuccessfulMutationResponse(deleteReplicaResponse, 'delete replica', 'either');
		await expect(replicasSection.getByRole('heading', { name: 'Read Replicas' })).toBeVisible();
		await expect(
			replicaRow(),
			`delete step should remove replica region ${selectedReplicaRegion} from the rendered table`
		).toHaveCount(0);
	});

	await test.step('post-refresh absence keeps the deleted replica row absent', async () => {
		await page.reload();
		await expect(replicasSection.getByRole('heading', { name: 'Read Replicas' })).toBeVisible();
		await expect(
			replicaRow(),
			`post-refresh absence should remove replica region ${selectedReplicaRegion}`
		).toHaveCount(0);
	});
});
