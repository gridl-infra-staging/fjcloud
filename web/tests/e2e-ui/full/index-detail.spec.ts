/**
 * Full — Index Detail Tabs
 *
 * Verifies the lazy-loaded tab sections on the index detail page:
 *   - Each tab section is NOT mounted before clicking the tab
 *   - Clicking a tab renders the section with correct empty-state content
 *
 * Ownership boundary:
 *   - indexes.spec.ts: list page, create, delete, basic detail smoke
 *   - search-preview.spec.ts: Search Preview tab
 *   - THIS FILE: Settings, Documents, Dictionaries, Rules, Synonyms, Chat tabs
 */

import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import { openIndexDetailTab, openSeededIndexDetailPage } from '../../fixtures/index_detail_helpers';

async function createSynonym(page: Page, objectId: string) {
	const section = await openIndexDetailTab(page, 'Synonyms', 'synonyms-section');
	await section.getByLabel('Object ID').fill(objectId);
	await section.getByRole('button', { name: 'Save Synonym' }).click();
	await expect(section.getByText('Synonym saved.')).toBeVisible();
	await expect(section.getByRole('cell', { name: objectId, exact: true })).toBeVisible();
	return section;
}

async function createExperiment(page: Page, name: string) {
	let section = await openIndexDetailTab(page, 'Experiments', 'experiments-section');
	await section.getByRole('button', { name: 'Create Experiment' }).click();
	const experimentNameInput = section.getByLabel('Experiment name', { exact: true });
	await experimentNameInput.fill(name);
	await expect(experimentNameInput).toHaveValue(name);
	await section.getByLabel('Enable rules', { exact: true }).check();
	await section.getByRole('button', { name: 'Launch Experiment', exact: true }).click();
	await expect(section.getByText('Failed to create experiment')).toHaveCount(0);
	await page.reload();
	section = await openIndexDetailTab(page, 'Experiments', 'experiments-section');
	await expect(section.getByRole('button', { name, exact: true })).toBeVisible();
	return section;
}

async function findExperimentRowActionButton(
	page: Page,
	experimentName: string,
	action: 'stop' | 'delete',
	maxAttempts = 4
) {
	const actionPattern = action === 'stop' ? /Stop experiment/i : /Delete experiment/i;
	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const section = await openIndexDetailTab(page, 'Experiments', 'experiments-section', false);
		const row = section
			.getByRole('row')
			.filter({ hasText: experimentName })
			.filter({ has: section.getByRole('button', { name: actionPattern }) });
		const rowActionButton = row.getByRole('button', { name: actionPattern }).first();
		if ((await rowActionButton.count()) > 0) return { section, row, rowActionButton };
		if (attempt < maxAttempts - 1) await page.reload();
	}
	throw new Error(`Could not find ${action} action for experiment ${experimentName}`);
}

test.describe('Index detail tabs', () => {
	test.describe.configure({ timeout: 90_000 });

	test('load-and-verify: seeded detail route lazy-mounts one tab on first click', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-load-verify');

		const section = await openIndexDetailTab(page, 'Settings', 'settings-section');
		await expect(section.getByLabel('Settings JSON')).toBeVisible();
		await expect(section.getByRole('button', { name: 'Save Settings' })).toBeVisible();
	});

	test('Experiments Stop typed confirm enforces no-op pre-confirm and submits after exact phrase', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-exp-stop');
		const experimentName = `exp-stop-${Date.now()}`;
		await createExperiment(page, experimentName);

		const { row, rowActionButton: stopButton } = await findExperimentRowActionButton(
			page,
			experimentName,
			'stop'
		);
		await stopButton.click();
		const dialog = page.getByTestId('confirm-dialog');
		await expect(dialog).toBeVisible();
		await expect(page.getByTestId('confirm-confirm-btn')).toBeDisabled();
		await page.getByTestId('confirm-input').fill(`${experimentName}-wrong`);
		await expect(page.getByTestId('confirm-confirm-btn')).toBeDisabled();
		await page.keyboard.press('Escape');
		await expect(dialog).toHaveCount(0);
		await expect(stopButton).toBeFocused();
		await expect(row.getByRole('cell', { name: 'Active' })).toBeVisible();

		await stopButton.click();
		await page.getByTestId('confirm-input').fill(experimentName);
		await expect(page.getByTestId('confirm-confirm-btn')).toBeEnabled();
		await page.getByTestId('confirm-confirm-btn').click();
		await expect(row.getByRole('cell', { name: 'Stopped' })).toBeVisible();
	});

	test('Experiments Delete typed confirm enforces no-op pre-confirm and deletes after confirm', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-exp-delete');
		const experimentName = `exp-delete-${Date.now()}`;
		await createExperiment(page, experimentName);

		const { row: stopRow, rowActionButton: stopButton } = await findExperimentRowActionButton(
			page,
			experimentName,
			'stop'
		);
		await stopButton.click();
		await expect(page.getByTestId('confirm-dialog')).toBeVisible();
		await page.getByTestId('confirm-input').fill(experimentName);
		await page.getByTestId('confirm-confirm-btn').click();
		await expect(stopRow.getByRole('cell', { name: 'Stopped' })).toBeVisible();

		const {
			section,
			row,
			rowActionButton: deleteButton
		} = await findExperimentRowActionButton(page, experimentName, 'delete');
		await deleteButton.click();
		await expect(page.getByTestId('confirm-dialog')).toBeVisible();
		await page.getByTestId('confirm-input').fill('mismatch');
		await expect(page.getByTestId('confirm-confirm-btn')).toBeDisabled();
		await page.getByTestId('confirm-cancel-btn').click();
		await expect(page.getByTestId('confirm-dialog')).toHaveCount(0);
		await expect(section.getByRole('cell', { name: experimentName, exact: true })).toBeVisible();

		await deleteButton.click();
		await page.getByTestId('confirm-input').fill(experimentName);
		await page.getByTestId('confirm-confirm-btn').click();
		await expect(row).toHaveCount(0);
		await expect(section.getByRole('button', { name: experimentName, exact: true })).toHaveCount(0);
	});

	test('Synonyms Delete standard confirm enforces no-op pre-confirm and deletes on confirm', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-syn-delete');
		const synonymObjectId = `syn-delete-${Date.now()}`;
		const section = await createSynonym(page, synonymObjectId);

		const deleteButton = section.getByRole('button', { name: `Delete synonym ${synonymObjectId}` });
		await deleteButton.click();
		await expect(page.getByTestId('confirm-dialog')).toBeVisible();
		await page.getByTestId('confirm-cancel-btn').click();
		await expect(page.getByTestId('confirm-dialog')).toHaveCount(0);
		await expect(section.getByRole('cell', { name: synonymObjectId, exact: true })).toBeVisible();

		await deleteButton.click();
		await page.getByTestId('confirm-confirm-btn').click();
		await expect(section.getByText('Synonym deleted.')).toBeVisible();
		await expect(section.getByRole('cell', { name: synonymObjectId, exact: true })).toHaveCount(0);
	});

	test('Settings tab lazy-mounts and shows Settings JSON editor', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-settings');
		const section = await openIndexDetailTab(page, 'Settings', 'settings-section');
		await expect(section.getByLabel('Settings JSON')).toBeVisible();
		await expect(section.getByRole('button', { name: 'Save Settings' })).toBeVisible();
	});

	test('Documents tab lazy-mounts and shows upload and browse controls', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-documents');
		const section = await openIndexDetailTab(page, 'Documents', 'documents-section');
		await expect(section.getByText('Upload JSON or CSV file')).toBeVisible();
		await expect(section.getByRole('button', { name: 'Browse Documents' })).toBeVisible();
	});

	test('Dictionaries tab lazy-mounts and shows browse and add entry controls', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-dictionaries');
		const section = await openIndexDetailTab(page, 'Dictionaries', 'dictionaries-section');
		await expect(section.getByRole('heading', { name: 'Browse Entries' })).toBeVisible();
		await expect(section.getByRole('heading', { name: 'Add Entry' })).toBeVisible();
	});

	test('Rules tab lazy-mounts and shows empty state', async ({ page, seedIndex, testRegion }) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-rules');
		const section = await openIndexDetailTab(page, 'Rules', 'rules-section');
		await expect(section.getByRole('heading', { name: 'Rules' })).toBeVisible();
		await expect(section.getByRole('button', { name: 'Add Rule', exact: true })).toBeVisible();
		await expect(section).toHaveAttribute('data-testid', 'rules-section');
	});

	test('Synonyms tab lazy-mounts and shows empty state', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-synonyms');
		const section = await openIndexDetailTab(page, 'Synonyms', 'synonyms-section');
		await expect(section.getByRole('heading', { name: 'Synonyms' })).toBeVisible();
		await expect(section.getByRole('heading', { name: 'Add or Update Synonym' })).toBeVisible();
		await expect(section.getByLabel('Object ID')).toBeVisible();
		await expect(section.getByRole('button', { name: 'Save Synonym' })).toBeVisible();
	});

	test('Chat tab lazy-mounts and shows query input and empty response', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-chat');
		const section = await openIndexDetailTab(page, 'Chat', 'chat-section');
		await expect(section.getByLabel('Query')).toBeVisible();
		await expect(section.getByText('Conversation History JSON')).toBeVisible();
		await expect(section.getByText('No chat response yet.')).toBeVisible();
	});

	test('Recommendations tab opens from clean detail route with related-products default selected', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const indexName = await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-detail-recommendations'
		);
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		const section = await openIndexDetailTab(page, 'Recommendations', 'recommendations-section');
		await expect(section.getByTestId('recommendations-model-select')).toHaveValue('related-products');
	});
});
