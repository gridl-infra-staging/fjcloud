import { test, expect, type CreatedFixtureUser } from '../../fixtures/fixtures';
import type { Locator, Page } from '@playwright/test';
import { createMerchandisingRule } from '../../../src/lib/utils/merchandising';
import type { Rule } from '../../../src/lib/api/types';
import { buildRuleDescription, buildRuleRowStatus } from '../../../src/lib/rules/ruleHelpers';

test.use({ storageState: { cookies: [], origins: [] } });

type SeedCustomerIndexFn = (
	customer: CreatedFixtureUser,
	name: string,
	region?: string
) => Promise<void>;

let activeCustomer: CreatedFixtureUser;

async function openMerchandisingTab(page: Page) {
	const section = page.getByTestId('merchandising-section');
	if ((await section.count()) > 0 && (await section.first().isVisible())) {
		return section;
	}
	await expect(page.getByTestId('index-tabs-strip')).toBeVisible();
	await expect(async () => {
		const merchandisingTab = page.getByRole('tab', { name: 'Merchandising', exact: true });
		await merchandisingTab.scrollIntoViewIfNeeded();
		await merchandisingTab.click();
		await expect(section).toBeVisible({ timeout: 10_000 });
	}).toPass({ timeout: 10_000 });
	return section;
}

async function gotoSeededIndexMerchandisingTab(
	page: Page,
	seedCustomerIndex: SeedCustomerIndexFn,
	customer: CreatedFixtureUser,
	testRegion: string,
	prefix: string
) {
	const indexName = `${prefix}-${Date.now()}`;
	await seedCustomerIndex(customer, indexName, testRegion);
	await expect(async () => {
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=merchandising`);
		await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 10_000 });
		await openMerchandisingTab(page);
	}).toPass({ timeout: 30_000 });
	return indexName;
}

async function openNewRuleDialog(page: Page) {
	const section = page.getByTestId('merchandising-section');
	await section.getByRole('button', { name: '+ New rule', exact: true }).click();
	const dialog = page.getByTestId('rules-editor-dialog');
	await expect(dialog).toBeVisible();
	await expectRuleEditorDialogTokens(page, dialog);
	return dialog;
}

async function expectClassTokens(locator: Locator, tokens: string[]): Promise<void> {
	const className = await locator.getAttribute('class');
	expect(className).not.toBeNull();
	const classTokens = className?.split(/\s+/).filter(Boolean) ?? [];
	for (const token of tokens) {
		expect(classTokens).toContain(token);
	}
}

async function expectRuleEditorDialogTokens(page: Page, dialog: Locator): Promise<void> {
	await expectClassTokens(page.getByTestId('editor-dialog-backdrop'), [
		'fixed',
		'inset-0',
		'bg-flapjack-ink/55'
	]);
	await expectClassTokens(dialog, ['bg-white', 'text-flapjack-ink', 'shadow-xl']);
	await expectClassTokens(page.getByTestId('editor-dialog-save'), [
		'bg-flapjack-rose',
		'hover:bg-flapjack-plum'
	]);
	await expectClassTokens(page.getByTestId('editor-dialog-cancel'), [
		'border-flapjack-ink/30',
		'text-flapjack-ink/80',
		'hover:bg-flapjack-cream/80'
	]);
}

async function expectMerchandisingRuleRowContract(row: Locator, rule: Rule): Promise<void> {
	await expect(row).toContainText(rule.objectID);
	await expect(row).toContainText(buildRuleDescription(rule));
	const status = buildRuleRowStatus(rule);
	if (status.isDraft) {
		await expect(row).toContainText(status.label);
	}
}

async function fillRuleEditorDialog(
	dialog: Locator,
	values: {
		objectID?: string;
		description?: string;
		queryPattern?: string;
		anchoring?: string;
		ruleState?: 'draft' | 'published';
		promoteObjectID?: string;
		promotePosition?: string;
		hideObjectID?: string;
	}
): Promise<void> {
	if (values.objectID !== undefined) {
		await dialog.getByLabel('Object ID').fill(values.objectID);
	}
	if (values.description !== undefined) {
		await dialog.getByLabel('Description').fill(values.description);
	}
	if (values.queryPattern !== undefined) {
		await dialog.getByLabel('Query pattern').fill(values.queryPattern);
	}
	if (values.anchoring !== undefined) {
		await dialog.getByLabel('Anchoring mode').selectOption(values.anchoring);
	}
	if (values.ruleState !== undefined) {
		await dialog.getByLabel('Rule state').selectOption(values.ruleState);
	}
	if (values.promoteObjectID !== undefined) {
		await dialog.getByLabel('Promote item ID').fill(values.promoteObjectID);
	}
	if (values.promotePosition !== undefined) {
		await dialog.getByLabel('Promote position').fill(values.promotePosition);
	}
	if (values.hideObjectID !== undefined) {
		await dialog.getByLabel('Hide item ID').fill(values.hideObjectID);
	}
}

async function readRuleEditorPreview(page: Page): Promise<Rule> {
	const previewLocator = page.getByTestId('rules-editor-json-preview');
	await expect(previewLocator).toContainText('"objectID"');
	return JSON.parse(await previewLocator.innerText()) as Rule;
}

test.describe('Merchandising hub CRUD', () => {
	test.describe.configure({ timeout: 90_000 });

	test.beforeEach(async ({ page, arrangeTrackedCustomerSession }) => {
		activeCustomer = await arrangeTrackedCustomerSession(page, {
			emailPrefix: 'e2e-merchandising-hub'
		});
	});

	test('Rules tab is gone and ?tab=rules routes to the merchandising hub', async ({
		page,
		seedCustomerIndex,
		testRegion
	}) => {
		const indexName = `e2e-merch-tab-norm-${Date.now()}`;
		await seedCustomerIndex(activeCustomer, indexName, testRegion);
		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
		await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 10_000 });
		await expect(page.getByTestId('index-tabs-strip')).toBeVisible();
		await expect(page.getByRole('tab', { name: 'Rules', exact: true })).toHaveCount(0);

		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=rules`);
		await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 10_000 });
		await expect(page.getByTestId('merchandising-section')).toBeVisible({ timeout: 10_000 });
	});

	test('+ New rule dialog renders diner tokens from consumer context', async ({
		page,
		seedCustomerIndex,
		testRegion
	}) => {
		await gotoSeededIndexMerchandisingTab(
			page,
			seedCustomerIndex,
			activeCustomer,
			testRegion,
			'e2e-merch-dialog-create'
		);

		const dialog = await openNewRuleDialog(page);
		await page.getByTestId('editor-dialog-cancel').click();
		await expect(dialog).toHaveCount(0);
	});

	test('create rule posts value-correct payload and renders row', async ({
		page,
		seedCustomerIndex,
		testRegion,
		getRule
	}) => {
		const indexName = await gotoSeededIndexMerchandisingTab(
			page,
			seedCustomerIndex,
			activeCustomer,
			testRegion,
			'e2e-merch-create'
		);
		const ruleObjectID = `create-rule-${Date.now()}`;
		const ruleDescription = `create description ${Date.now()}`;
		const conditionPattern = `pattern-${Date.now()}`;
		const promoteObjectID = `promote-${Date.now()}`;
		const promotePosition = '3';

		const dialog = await openNewRuleDialog(page);
		await fillRuleEditorDialog(dialog, {
			objectID: ruleObjectID,
			description: ruleDescription,
			queryPattern: conditionPattern,
			anchoring: 'contains',
			ruleState: 'draft',
			promoteObjectID,
			promotePosition
		});
		const previewRule = await readRuleEditorPreview(page);
		expect(previewRule.conditions).toEqual([{ pattern: conditionPattern, anchoring: 'contains' }]);
		expect(previewRule.enabled).toBe(false);
		await dialog.getByRole('button', { name: 'Create' }).click();

		const section = await openMerchandisingTab(page);
		const row = section.getByTestId(`merchandising-rule-row-${ruleObjectID}`);
		await expect(row).toBeVisible();
		await expectMerchandisingRuleRowContract(row, {
			objectID: ruleObjectID,
			description: ruleDescription,
			enabled: false,
			conditions: [{ pattern: conditionPattern, anchoring: 'contains' }],
			consequence: {
				promote: [{ objectID: promoteObjectID, position: Number(promotePosition) }]
			}
		});

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
		seedCustomerIndex,
		testRegion,
		seedRules,
		getRule
	}) => {
		const indexName = await gotoSeededIndexMerchandisingTab(
			page,
			seedCustomerIndex,
			activeCustomer,
			testRegion,
			'e2e-merch-edit'
		);
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
		const section = await openMerchandisingTab(page);
		const row = section.getByTestId(`merchandising-rule-row-${objectID}`);
		await expect(row).toBeVisible();
		await row.getByRole('button', { name: `Edit rule ${objectID}` }).click();

		const dialog = page.getByTestId('rules-editor-dialog');
		await expect(dialog).toBeVisible();
		await expectRuleEditorDialogTokens(page, dialog);
		await expect(page.getByTestId('rules-editor-object-id-readonly')).toHaveText(objectID);

		const updatedDescription = `after-edit-${Date.now()}`;
		const updatedPromoteObjectID = `after-promote-${Date.now()}`;
		await dialog.getByLabel('Description').fill(updatedDescription);
		await dialog.getByLabel('Promote item ID').fill(updatedPromoteObjectID);
		await dialog.getByLabel('Promote position').fill('4');
		await dialog.getByRole('button', { name: 'Save' }).click();

		const updatedSection = await openMerchandisingTab(page);
		const updatedRow = updatedSection.getByTestId(`merchandising-rule-row-${objectID}`);
		await expectMerchandisingRuleRowContract(updatedRow, {
			objectID,
			description: updatedDescription,
			enabled: true,
			conditions: [{ pattern: 'edit-pattern', anchoring: 'is' }],
			consequence: {
				promote: [{ objectID: updatedPromoteObjectID, position: 4 }]
			}
		});

		const backendRule = await getRule(indexName, objectID);
		expect(backendRule.objectID).toBe(objectID);
		expect(backendRule.description).toBe(updatedDescription);
		expect(backendRule.consequence.promote).toEqual([
			{ objectID: updatedPromoteObjectID, position: 4 }
		]);
	});

	test('JSON preview matches saved backend payload', async ({
		page,
		seedCustomerIndex,
		testRegion,
		getRule
	}) => {
		const indexName = await gotoSeededIndexMerchandisingTab(
			page,
			seedCustomerIndex,
			activeCustomer,
			testRegion,
			'e2e-merch-preview'
		);
		const objectID = `preview-${Date.now()}`;
		const description = `preview-desc-${Date.now()}`;
		const conditionPattern = `preview-pattern-${Date.now()}`;
		const promoteObjectID = `preview-promote-${Date.now()}`;

		const dialog = await openNewRuleDialog(page);
		await fillRuleEditorDialog(dialog, {
			objectID,
			description,
			queryPattern: conditionPattern,
			anchoring: 'startsWith',
			promoteObjectID,
			promotePosition: '2'
		});

		const parsedPreview = await readRuleEditorPreview(page);
		await dialog.getByRole('button', { name: 'Create' }).click();

		const backendRule = await getRule(indexName, objectID);
		expect(backendRule.objectID).toBe(parsedPreview.objectID);
		expect(backendRule.description).toBe(parsedPreview.description);
		expect(backendRule.conditions).toEqual(parsedPreview.conditions);
		expect(backendRule.consequence).toEqual(parsedPreview.consequence);
	});

	test('publish draft rule flips enabled to true and preserves every other field', async ({
		page,
		seedCustomerIndex,
		testRegion,
		seedRules,
		getRule
	}) => {
		const indexName = await gotoSeededIndexMerchandisingTab(
			page,
			seedCustomerIndex,
			activeCustomer,
			testRegion,
			'e2e-merch-publish'
		);
		const objectID = `draft-${Date.now()}`;
		const draftDescription = `draft-desc-${Date.now()}`;
		const draftConditions = [{ pattern: `draft-pattern-${Date.now()}`, anchoring: 'is' as const }];
		const draftPromote = [{ objectID: `draft-promote-${Date.now()}`, position: 2 }];
		await seedRules(indexName, [
			{
				objectID,
				description: draftDescription,
				enabled: false,
				conditions: draftConditions,
				consequence: { promote: draftPromote }
			}
		]);
		const seededRule = await getRule(indexName, objectID);
		expect(seededRule.enabled).toBe(false);

		await page.reload();
		const section = await openMerchandisingTab(page);
		const row = section.getByTestId(`merchandising-rule-row-${objectID}`);
		await expect(row).toBeVisible();
		await expect(row).toContainText('Draft');
		await row.getByRole('button', { name: `Publish rule ${objectID}` }).click();

		await expect
			.poll(
				async () => {
					const refreshed = await getRule(indexName, objectID);
					return refreshed.enabled;
				},
				{ timeout: 15_000 }
			)
			.toBe(true);

		const publishedRule = await getRule(indexName, objectID);
		expect(publishedRule.objectID).toBe(objectID);
		expect(publishedRule.description).toBe(draftDescription);
		expect(publishedRule.conditions).toEqual(draftConditions);
		expect(publishedRule.consequence.promote).toEqual(draftPromote);
		expect(publishedRule.enabled).toBe(true);
	});

	test('delete single rule removes row and backend hit', async ({
		page,
		seedCustomerIndex,
		testRegion,
		seedRules,
		searchRules
	}) => {
		const indexName = await gotoSeededIndexMerchandisingTab(
			page,
			seedCustomerIndex,
			activeCustomer,
			testRegion,
			'e2e-merch-delete'
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
			const reloadedSection = await openMerchandisingTab(page);
			await expect(
				reloadedSection.getByTestId(`merchandising-rule-row-${deleteObjectID}`)
			).toBeVisible({ timeout: 5_000 });
		}).toPass({ timeout: 20_000 });

		const section = await openMerchandisingTab(page);
		const row = section.getByTestId(`merchandising-rule-row-${deleteObjectID}`);
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
		seedCustomerIndex,
		testRegion,
		seedRules,
		searchRules
	}) => {
		const indexName = await gotoSeededIndexMerchandisingTab(
			page,
			seedCustomerIndex,
			activeCustomer,
			testRegion,
			'e2e-merch-clear'
		);
		const ruleA = `clear-a-${Date.now()}`;
		const ruleB = `clear-b-${Date.now()}`;
		await seedRules(indexName, [
			{ objectID: ruleA, conditions: [{ pattern: 'clear-a', anchoring: 'is' }], consequence: {} },
			{ objectID: ruleB, conditions: [{ pattern: 'clear-b', anchoring: 'is' }], consequence: {} }
		]);
		await page.reload();
		const section = await openMerchandisingTab(page);
		await section.getByRole('button', { name: 'Clear All Rules', exact: true }).click();
		await expect(page.getByTestId('confirm-dialog')).toBeVisible();
		await page.getByTestId('confirm-input').fill('clear all rules');
		await page.getByTestId('confirm-confirm-btn').click();

		await expect(section.getByText('No merchandising rules yet')).toBeVisible();
		const afterSearch = await searchRules(indexName, '', 0, 50);
		expect(afterSearch.nbHits).toBe(0);
	});

	test('multi-page clear all deletes more than first page of rules', async ({
		page,
		seedCustomerIndex,
		testRegion,
		seedRules,
		searchRules
	}) => {
		const indexName = await gotoSeededIndexMerchandisingTab(
			page,
			seedCustomerIndex,
			activeCustomer,
			testRegion,
			'e2e-merch-clear-many'
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
		const section = await openMerchandisingTab(page);
		await section.getByRole('button', { name: 'Clear All Rules', exact: true }).click();
		await expect(page.getByTestId('confirm-dialog')).toBeVisible();
		await page.getByTestId('confirm-input').fill('clear all rules');
		await page.getByTestId('confirm-confirm-btn').click();

		await expect(section.getByText('No merchandising rules yet')).toBeVisible();
		const afterSearch = await searchRules(indexName, '', 0, 50);
		expect(afterSearch.nbHits).toBe(0);
	});

	test('merchandising helper payload survives saveRule wire contract', async ({
		page,
		seedCustomerIndex,
		testRegion,
		getRule
	}) => {
		const indexName = await gotoSeededIndexMerchandisingTab(
			page,
			seedCustomerIndex,
			activeCustomer,
			testRegion,
			'e2e-merch-helper'
		);
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

		const dialog = await openNewRuleDialog(page);
		await fillRuleEditorDialog(dialog, {
			objectID: expectedRule.objectID,
			description,
			queryPattern: query,
			anchoring: 'is',
			ruleState: 'published',
			promoteObjectID,
			promotePosition: String(promotePosition),
			hideObjectID: hiddenObjectID
		});
		const previewRule = await readRuleEditorPreview(page);
		expect(previewRule.conditions).toEqual(expectedRule.conditions);
		expect(previewRule.consequence).toEqual(expectedRule.consequence);
		await dialog.getByRole('button', { name: 'Create' }).click();

		const backendRule = await getRule(indexName, expectedRule.objectID);
		expect(backendRule.consequence.promote).toEqual(expectedRule.consequence.promote);
		expect(backendRule.consequence.hide).toEqual(expectedRule.consequence.hide);
	});
});
