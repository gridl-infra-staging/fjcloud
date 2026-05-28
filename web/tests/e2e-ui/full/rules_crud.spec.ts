import { test, expect } from '../../fixtures/fixtures';
import type { Page } from '@playwright/test';
import { createMerchandisingRule } from '../../../src/lib/utils/merchandising';

type SeedIndexFn = (name: string, region?: string) => Promise<void>;

async function openRulesTab(page: Page) {
	const section = page.getByTestId('rules-section');
	if ((await section.count()) > 0 && (await section.first().isVisible())) {
		return section;
	}
	await expect(section).toHaveCount(0);
	await expect(page.getByTestId('index-tabs-strip')).toBeVisible();
	await expect(async () => {
		const rulesTab = page.getByRole('tab', { name: 'Rules', exact: true });
		await rulesTab.scrollIntoViewIfNeeded();
		await rulesTab.click();
		await expect(section).toBeVisible({ timeout: 10_000 });
	}).toPass({ timeout: 10_000 });
	return section;
}

async function gotoSeededIndexRulesTab(
	page: Page,
	seedIndex: SeedIndexFn,
	testRegion: string,
	prefix: string
) {
	const indexName = `${prefix}-${Date.now()}`;
	await seedIndex(indexName, testRegion);
	await expect(async () => {
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 10_000 });
		await openRulesTab(page);
	}).toPass({ timeout: 30_000 });
	return indexName;
}

async function openAddRuleDialog(page: Page) {
	const section = page.getByTestId('rules-section');
	await section.getByRole('button', { name: 'Add Rule', exact: true }).click();
	const dialog = page.getByTestId('rules-editor-dialog');
	await expect(dialog).toBeVisible();
	return dialog;
}

test.describe('Rules CRUD', () => {
	test.describe.configure({ timeout: 90_000 });

	test('create rule posts value-correct payload and renders row', async ({
		page,
		seedIndex,
		testRegion,
		getRule
	}) => {
		const indexName = await gotoSeededIndexRulesTab(
			page,
			seedIndex,
			testRegion,
			'e2e-rules-create'
		);
		const ruleObjectID = `create-rule-${Date.now()}`;
		const ruleDescription = `create description ${Date.now()}`;
		const conditionPattern = `pattern-${Date.now()}`;
		const promoteObjectID = `promote-${Date.now()}`;
		const promotePosition = '3';

		const dialog = await openAddRuleDialog(page);
		await dialog.getByLabel('Object ID').fill(ruleObjectID);
		await dialog.getByLabel('Description').fill(ruleDescription);
		await dialog.getByLabel('Enabled').uncheck();
		await dialog
			.getByLabel('Conditions JSON')
			.fill(JSON.stringify([{ pattern: conditionPattern, anchoring: 'contains' }], null, 2));
		await dialog.getByLabel('Promote item ID').fill(promoteObjectID);
		await dialog.getByLabel('Promote position').fill(promotePosition);
		await dialog.getByRole('button', { name: 'Create' }).click();

		const section = await openRulesTab(page);
		const row = section.getByRole('row').filter({ hasText: ruleObjectID });
		await expect(row).toBeVisible();
		await expect(row.getByRole('cell', { name: ruleDescription, exact: true })).toBeVisible();

		const backendRule = await getRule(indexName, ruleObjectID);
		expect(backendRule.objectID).toBe(ruleObjectID);
		expect(backendRule.description).toBe(ruleDescription);
		expect(backendRule.enabled).toBe(false);
		expect(backendRule.conditions).toEqual([{ pattern: conditionPattern, anchoring: 'contains' }]);
		expect(backendRule.consequence.promote).toEqual([
			{ objectID: promoteObjectID, position: Number(promotePosition) }
		]);
	});

	test('edit rule keeps objectID read-only and updates selected fields', async ({
		page,
		seedIndex,
		testRegion,
		seedRules,
		getRule
	}) => {
		const indexName = await gotoSeededIndexRulesTab(page, seedIndex, testRegion, 'e2e-rules-edit');
		const objectID = `edit-target-${Date.now()}`;
		await seedRules(indexName, [
			{
				objectID,
				description: 'before-edit',
				enabled: true,
				conditions: [{ pattern: 'edit-pattern', anchoring: 'is' }],
				consequence: {
					promote: [{ objectID: 'before-promote', position: 1 }]
				}
			}
		]);
		await page.reload();
		const section = await openRulesTab(page);
		const row = section.getByRole('row').filter({ hasText: objectID });
		await row.getByRole('button', { name: `Edit rule ${objectID}` }).click();

		const dialog = page.getByTestId('rules-editor-dialog');
		await expect(dialog).toBeVisible();
		await expect(page.getByTestId('rules-editor-object-id-readonly')).toHaveText(objectID);

		const updatedDescription = `after-edit-${Date.now()}`;
		const updatedPromoteObjectID = `after-promote-${Date.now()}`;
		await dialog.getByLabel('Description').fill(updatedDescription);
		await dialog.getByLabel('Promote item ID').fill(updatedPromoteObjectID);
		await dialog.getByLabel('Promote position').fill('4');
		await dialog.getByRole('button', { name: 'Save' }).click();

		const updatedSection = await openRulesTab(page);
		const updatedRow = updatedSection.getByRole('row').filter({ hasText: objectID });
		await expect(
			updatedRow.getByRole('cell', { name: updatedDescription, exact: true })
		).toBeVisible();

		const backendRule = await getRule(indexName, objectID);
		expect(backendRule.objectID).toBe(objectID);
		expect(backendRule.description).toBe(updatedDescription);
		expect(backendRule.consequence.promote).toEqual([
			{ objectID: updatedPromoteObjectID, position: 4 }
		]);
	});

	test('JSON preview matches saved backend payload', async ({
		page,
		seedIndex,
		testRegion,
		getRule
	}) => {
		const indexName = await gotoSeededIndexRulesTab(
			page,
			seedIndex,
			testRegion,
			'e2e-rules-preview'
		);
		const objectID = `preview-${Date.now()}`;
		const description = `preview-desc-${Date.now()}`;
		const conditionPattern = `preview-pattern-${Date.now()}`;
		const promoteObjectID = `preview-promote-${Date.now()}`;

		const dialog = await openAddRuleDialog(page);
		await dialog.getByLabel('Object ID').fill(objectID);
		await dialog.getByLabel('Description').fill(description);
		await dialog
			.getByLabel('Conditions JSON')
			.fill(JSON.stringify([{ pattern: conditionPattern, anchoring: 'startsWith' }], null, 2));
		await dialog.getByLabel('Promote item ID').fill(promoteObjectID);
		await dialog.getByLabel('Promote position').fill('2');

		const previewLocator = page.getByTestId('rules-editor-json-preview');
		await expect(previewLocator).toContainText('"objectID"');
		const previewJson = await previewLocator.innerText();
		const parsedPreview = JSON.parse(previewJson ?? '{}');
		await dialog.getByRole('button', { name: 'Create' }).click();

		const backendRule = await getRule(indexName, objectID);
		expect(backendRule.objectID).toBe(parsedPreview.objectID);
		expect(backendRule.description).toBe(parsedPreview.description);
		expect(backendRule.conditions).toEqual(parsedPreview.conditions);
		expect(backendRule.consequence).toEqual(parsedPreview.consequence);
	});

	test('delete single rule removes row and backend hit', async ({
		page,
		seedIndex,
		testRegion,
		seedRules,
		searchRules
	}) => {
		const indexName = await gotoSeededIndexRulesTab(
			page,
			seedIndex,
			testRegion,
			'e2e-rules-delete'
		);
		const keepObjectID = `keep-${Date.now()}`;
		const deleteObjectID = `delete-${Date.now()}`;
		await seedRules(indexName, [
			{
				objectID: keepObjectID,
				conditions: [{ pattern: 'keep', anchoring: 'is' }],
				consequence: {}
			},
			{
				objectID: deleteObjectID,
				description: 'delete-me',
				conditions: [{ pattern: 'delete-me', anchoring: 'contains' }],
				consequence: {}
			}
		]);
		await expect
			.poll(
				async () => {
					const seeded = await searchRules(indexName, '', 0, 50);
					return seeded.hits.some((hit) => hit.objectID === deleteObjectID);
				},
				{ timeout: 15_000 }
			)
			.toBe(true);
		await expect(async () => {
			await page.reload();
			const reloadedSection = await openRulesTab(page);
			await expect(
				reloadedSection.getByRole('row').filter({ hasText: deleteObjectID })
			).toBeVisible({ timeout: 5_000 });
		}).toPass({ timeout: 20_000 });

		const section = await openRulesTab(page);
		const row = section.getByRole('row').filter({ hasText: deleteObjectID });
		const beforeSearch = await searchRules(indexName, '', 0, 50);

		await row.getByRole('button', { name: `Delete rule ${deleteObjectID}` }).click();
		const dialog = page.getByTestId('confirm-dialog');
		await expect(dialog).toBeVisible();
		await page.getByTestId('confirm-confirm-btn').click();

		await expect(row).toHaveCount(0);
		const afterSearch = await searchRules(indexName, '', 0, 50);
		expect(afterSearch.nbHits).toBe(beforeSearch.nbHits - 1);
		expect(afterSearch.hits.some((hit) => hit.objectID === deleteObjectID)).toBe(false);
	});

	test('clear all rules removes all hits and shows no rules state', async ({
		page,
		seedIndex,
		testRegion,
		seedRules,
		searchRules
	}) => {
		const indexName = await gotoSeededIndexRulesTab(page, seedIndex, testRegion, 'e2e-rules-clear');
		const ruleA = `clear-a-${Date.now()}`;
		const ruleB = `clear-b-${Date.now()}`;
		await seedRules(indexName, [
			{ objectID: ruleA, conditions: [{ pattern: 'clear-a', anchoring: 'is' }], consequence: {} },
			{ objectID: ruleB, conditions: [{ pattern: 'clear-b', anchoring: 'is' }], consequence: {} }
		]);
		await page.reload();
		const section = await openRulesTab(page);
		await section.getByRole('button', { name: 'Clear All Rules', exact: true }).click();
		await expect(page.getByTestId('confirm-dialog')).toBeVisible();
		await page.getByTestId('confirm-input').fill('clear all rules');
		await page.getByTestId('confirm-confirm-btn').click();

		await expect(section.getByText('No rules')).toBeVisible();
		const afterSearch = await searchRules(indexName, '', 0, 50);
		expect(afterSearch.nbHits).toBe(0);
	});

	test('multi-page clear all deletes more than first page of rules', async ({
		page,
		seedIndex,
		testRegion,
		seedRules,
		searchRules
	}) => {
		const indexName = await gotoSeededIndexRulesTab(
			page,
			seedIndex,
			testRegion,
			'e2e-rules-clear-many'
		);
		const now = Date.now();
		const seededRules = Array.from({ length: 51 }, (_, idx) => ({
			objectID: `bulk-clear-${now}-${idx}`,
			description: `bulk clear ${idx}`,
			conditions: [{ pattern: `bulk-${idx}`, anchoring: 'contains' as const }],
			consequence: {}
		}));
		await seedRules(indexName, seededRules);
		await page.reload();
		const section = await openRulesTab(page);
		await section.getByRole('button', { name: 'Clear All Rules', exact: true }).click();
		await expect(page.getByTestId('confirm-dialog')).toBeVisible();
		await page.getByTestId('confirm-input').fill('clear all rules');
		await page.getByTestId('confirm-confirm-btn').click();

		await expect(section.getByText('No rules')).toBeVisible();
		const afterSearch = await searchRules(indexName, '', 0, 50);
		expect(afterSearch.nbHits).toBe(0);
	});

	test('merchandising helper payload survives saveRule wire contract', async ({
		page,
		seedIndex,
		testRegion,
		getRule
	}) => {
		const indexName = await gotoSeededIndexRulesTab(page, seedIndex, testRegion, 'e2e-rules-merch');
		const timestamp = Date.now();
		const query = `merch-query-${timestamp}`;
		const description = `merch-description-${timestamp}`;
		const promoteObjectID = `promote-merch-${timestamp}`;
		const promotePosition = 2;
		const hiddenObjectID = `hide-merch-${timestamp}`;
		const expectedRule = createMerchandisingRule({
			query,
			description,
			pins: [{ objectID: promoteObjectID, position: promotePosition }],
			hides: [{ objectID: hiddenObjectID }],
			timestamp
		});

		const dialog = await openAddRuleDialog(page);
		await dialog.getByLabel('Object ID').fill(expectedRule.objectID);
		await dialog.getByLabel('Description').fill(description);
		await dialog
			.getByLabel('Conditions JSON')
			.fill(JSON.stringify(expectedRule.conditions, null, 2));
		await dialog.getByLabel('Promote item ID').fill(promoteObjectID);
		await dialog.getByLabel('Promote position').fill(String(promotePosition));
		await dialog.getByLabel('Hide item ID').fill(hiddenObjectID);
		await dialog.getByRole('button', { name: 'Create' }).click();

		const backendRule = await getRule(indexName, expectedRule.objectID);
		expect(backendRule.consequence.promote).toEqual(expectedRule.consequence.promote);
		expect(backendRule.consequence.hide).toEqual(expectedRule.consequence.hide);
	});
});
