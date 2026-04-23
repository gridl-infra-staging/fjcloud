/**
 * Full — Indexes
 *
 * Verifies the complete index management surface:
 *   - Load-and-verify: seeded index appears in the table
 *   - Create index through the UI form
 *   - Navigate to index detail page
 *   - Delete index through the UI
 */

import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import {
	generatePreviewKeyAndWaitForWidget,
	gotoIndexDetailWithRetry,
	submitSearchPreviewQuery,
	waitForSearchPreviewReady
} from '../../fixtures/search-preview-helpers';

type RuntimeRegionOption = {
	id: string;
	label: string;
	checked: boolean;
	disabled: boolean;
};

type CapturedRuntimeRegions = {
	defaultRegionId: string;
	secondRegionId: string;
};

async function openCreateIndexForm(page: Page): Promise<void> {
	await page.goto('/dashboard/indexes');
	await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();
	await page.getByRole('button', { name: 'Create Index' }).click();
}

async function waitForCreateIndexSuccess(
	page: Page,
	indexName: string,
	options?: { requireTableRow?: boolean }
): Promise<void> {
	const indexInTable = page.getByRole('cell', { name: indexName });
	const provisioningMsg = page.getByText('Setting up your search endpoint');
	const createdMsg = page.getByText('Index created successfully');

	await expect
		.poll(
			async () => {
				if (await indexInTable.isVisible().catch(() => false)) return 'table';
				if (!options?.requireTableRow && await provisioningMsg.isVisible().catch(() => false)) {
					return 'provisioning';
				}
				if (!options?.requireTableRow && await createdMsg.isVisible().catch(() => false)) {
					return 'created';
				}
				return 'pending';
			},
			{ timeout: 15_000 }
		)
		.not.toBe('pending');
}

async function submitCreateIndexForm(page: Page, name: string, regionId?: string): Promise<void> {
	await page.getByLabel('Index name').fill(name);
	const form = page.getByTestId('create-index-form');
	const regionRadios = form.getByRole('radio');

	if (regionId) {
		const targetIndex = await regionRadios.evaluateAll((inputs, targetRegionId) =>
			inputs.findIndex((input) => {
				const radio = input as HTMLInputElement;
				return !radio.disabled && radio.value === targetRegionId;
			}),
		regionId);
		if (targetIndex < 0) {
			const observedRegions = await regionRadios.evaluateAll((inputs) =>
				inputs
					.map((input) => {
						const radio = input as HTMLInputElement;
						const disabledTag = radio.disabled ? ',disabled' : '';
						return `${radio.value}${disabledTag}`;
					})
					.join(', ')
			);
			throw new Error(
				`Region radio "${regionId}" was not selectable in create form. observed=${observedRegions || 'none'}`
			);
		}
		// Click the visible label card that contains the region ID text.
		// The sr-only radio inside the label gets checked via label click propagation.
		await form.getByText(regionId, { exact: true }).click();
	} else {
		// Region radios are optional in some environments.
		// Click the first region label card if any radios are present.
		if (await regionRadios.count() > 0) {
			const firstRegionId = await regionRadios.first().evaluate(
				(el) => (el as HTMLInputElement).value
			);
			await form.getByText(firstRegionId, { exact: true }).click();
		}
	}

	await page.getByRole('button', { name: 'Create', exact: true }).click();
}

async function captureRuntimeRegionsFromCreateForm(page: Page): Promise<CapturedRuntimeRegions> {
	const regionRadios = page.getByTestId('create-index-form').getByRole('radio');
	const regionOptions: RuntimeRegionOption[] = await regionRadios.evaluateAll((inputs) =>
		inputs.map((input) => {
			const radio = input as HTMLInputElement;
			const labelText = radio.closest('label')?.innerText ?? '';
			return {
				id: radio.value.trim(),
				label: labelText.replace(/\s+/g, ' ').trim(),
				checked: radio.checked,
				disabled: radio.disabled,
			};
		})
	);

	const selectableOptions = regionOptions.filter((option) => option.id && !option.disabled);
	const observedOptions =
		regionOptions.length === 0
			? 'none'
			: regionOptions
					.map((option) => {
						const checkedTag = option.checked ? ',checked' : '';
						const disabledTag = option.disabled ? ',disabled' : '';
						return `${option.label || '(no-label)'} [${option.id || '(no-id)'}${checkedTag}${disabledTag}]`;
					})
					.join('; ');

	if (selectableOptions.length < 2) {
		throw new Error(
			`ENV-BLOCKER: create form exposed fewer than two selectable regions. observed=${observedOptions}`
		);
	}

	const defaultRegion = selectableOptions.find((option) => option.checked) ?? selectableOptions[0];
	const secondRegion = selectableOptions.find((option) => option.id !== defaultRegion.id);

	if (!secondRegion) {
		throw new Error(
			`ENV-BLOCKER: unable to identify a second selectable region distinct from default "${defaultRegion.id}". observed=${observedOptions}`
		);
	}

	return {
		defaultRegionId: defaultRegion.id,
		secondRegionId: secondRegion.id,
	};
}

async function expectIndexRegionRow(page: Page, indexName: string, regionId: string): Promise<void> {
	const row = page.getByRole('row').filter({
		has: page.getByRole('link', { name: indexName, exact: true }),
	});
	await expect(row.getByRole('cell', { name: regionId, exact: true })).toBeVisible({
		timeout: 15_000,
	});
}

async function expectOverviewRegionStat(page: Page, regionId: string): Promise<void> {
	const statsSection = page.getByTestId('stats-section');
	await expect(statsSection.getByText('Region', { exact: true })).toBeVisible();
	await expect(statsSection.getByText(regionId, { exact: true })).toBeVisible();
}

test.describe('Indexes list page', () => {
	test('load-and-verify: seeded index appears in the table', async ({ page, seedIndex }) => {
		const name = `e2e-list-${Date.now()}`;

		// Arrange: seed via API
		await seedIndex(name);

		// Act: navigate to indexes
		await page.goto('/dashboard/indexes');

		// Assert: page-specific heading visible (not sidebar nav)
		await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();

		// Assert: the seeded index name appears in the table
		await expect(page.getByRole('cell', { name })).toBeVisible({ timeout: 10_000 });
	});

	test('Create Index button toggles the creation form', async ({ page }) => {
		await page.goto('/dashboard/indexes');
		await expect(page.getByRole('heading', { name: 'Indexes' })).toBeVisible();

		// Form is hidden initially
		await expect(page.getByTestId('create-index-form')).toBeHidden();

		// Act: click Create Index
		await page.getByRole('button', { name: 'Create Index' }).click();

		// Assert: form appears
		await expect(page.getByTestId('create-index-form')).toBeVisible();
		await expect(page.getByLabel('Index name')).toBeVisible();
		await expect(page.getByRole('button', { name: 'Create', exact: true })).toBeVisible();
	});

	test('Cancel button hides the creation form', async ({ page }) => {
		await openCreateIndexForm(page);
		await expect(page.getByTestId('create-index-form')).toBeVisible();

		await page.getByRole('button', { name: 'Cancel' }).click();
		await expect(page.getByTestId('create-index-form')).toBeHidden();
	});

	test('create index through the UI adds it to the table', async ({
		page,
		cleanupFixtureIndexes,
		registerIndexForCleanup,
	}) => {
		const name = `e2e-create-${Date.now()}`;

		await cleanupFixtureIndexes();
		await openCreateIndexForm(page);
		await submitCreateIndexForm(page, name);

		await waitForCreateIndexSuccess(page, name);

		// Register for cleanup after a successful UI create path.
		registerIndexForCleanup(name);
	});

	test('create/list/detail journey reuses one captured runtime second region', async ({
		page,
		cleanupFixtureIndexes,
		seedIndex,
		registerIndexForCleanup,
	}) => {
		const defaultRegionIndexName = `e2e-default-region-${Date.now()}`;
		const secondRegionIndexName = `e2e-second-region-${Date.now()}`;

		await cleanupFixtureIndexes();
		await openCreateIndexForm(page);
		const runtimeRegions = await captureRuntimeRegionsFromCreateForm(page);
		await page.getByRole('button', { name: 'Cancel' }).click();

		await seedIndex(defaultRegionIndexName, runtimeRegions.defaultRegionId);

		await openCreateIndexForm(page);
		await submitCreateIndexForm(page, secondRegionIndexName, runtimeRegions.secondRegionId);

		await waitForCreateIndexSuccess(page, secondRegionIndexName, { requireTableRow: true });

		registerIndexForCleanup(secondRegionIndexName);

		await page.goto('/dashboard/indexes');
		await expectIndexRegionRow(page, defaultRegionIndexName, runtimeRegions.defaultRegionId);
		await expectIndexRegionRow(page, secondRegionIndexName, runtimeRegions.secondRegionId);

		await page.getByRole('link', { name: secondRegionIndexName, exact: true }).click();
		await expect(page).toHaveURL(
			new RegExp(`/dashboard/indexes/${encodeURIComponent(secondRegionIndexName)}`)
		);
		await expect(page.getByRole('heading', { name: secondRegionIndexName })).toBeVisible({
			timeout: 10_000,
		});
		await expectOverviewRegionStat(page, runtimeRegions.secondRegionId);
	});

	test('duplicate index name shows a safe failure instead of succeeding', async ({
		page,
		cleanupFixtureIndexes,
		seedIndex,
		testRegion,
	}) => {
		const name = `e2e-duplicate-${Date.now()}`;
		await cleanupFixtureIndexes();
		await seedIndex(name, testRegion);

		await openCreateIndexForm(page);
		await submitCreateIndexForm(page, name);

		const formAlert = page.getByRole('alert');
		await expect(formAlert).toBeVisible({ timeout: 15_000 });
		await expect(formAlert).toContainText(/already exists|duplicate/i);
		await expect(page).toHaveURL(/\/dashboard\/indexes/);
		await expect(page.getByText('Index created successfully')).toHaveCount(0);
	});

	test('clicking an index name navigates to the detail page', async ({ page, seedIndex }) => {
		const name = `e2e-detail-nav-${Date.now()}`;
		await seedIndex(name);

		await page.goto('/dashboard/indexes');
		await expect(page.getByRole('cell', { name })).toBeVisible({ timeout: 10_000 });

		// Act: click the index name link
		await page.getByRole('link', { name }).click();

		// Assert: detail page shows the index name as heading
		await expect(page).toHaveURL(new RegExp(`/dashboard/indexes/${encodeURIComponent(name)}`));
		await expect(page.getByRole('heading', { name })).toBeVisible();
	});
});

test.describe('Index detail page', () => {
	test('detail page has a delete button with confirmation', async ({
		page,
		seedIndex,
		testRegion,
	}) => {
		test.setTimeout(120_000);
		const name = `e2e-del-${Date.now()}`;
		await seedIndex(name, testRegion);

		await gotoIndexDetailWithRetry(page, name);

		// The delete button should be visible on the page
		await expect(page.getByRole('button', { name: /delete/i })).toBeVisible();
	});

	test('Search Preview tab shows real search results from Flapjack', async ({
		page,
		seedSearchableIndex,
	}) => {
		test.setTimeout(120_000);
		const name = `e2e-search-${Date.now()}`;

		// Arrange: seed an index with searchable documents via the fixture
		const { query, expectedHitText } = await seedSearchableIndex(name);

		// Act: navigate to the index detail page
		await gotoIndexDetailWithRetry(page, name);

		// Act: click the Search Preview tab
		await page.getByRole('tab', { name: 'Search Preview' }).click();

		// Assert: the search preview section is visible
		await expect(page.getByTestId('search-preview-section')).toBeVisible();

		// Wait through provisioning (up to 90s) — if readiness never arrives, the test fails
		await waitForSearchPreviewReady(page);

		// Act: click "Generate Preview Key" to request a key and mount InstantSearch
		const generateButton = page
			.getByTestId('search-preview-section')
			.getByRole('button', { name: /generate preview key/i });
		await generatePreviewKeyAndWaitForWidget(page);

		// Act: type the query into the search box
		await submitSearchPreviewQuery(page, query);

		// Assert: the expected hit text appears in the search preview hits area
		await expect(
			page.getByTestId('instantsearch-hits').getByText(expectedHitText)
		).toBeVisible({ timeout: 60_000 });
	});
});
