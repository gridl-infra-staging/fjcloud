import * as devalue from 'devalue';
import type { Locator, Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import {
	assertSingleVisiblePersonalizationProfileState,
	openIndexDetailTab,
	openSeededIndexDetailPage
} from './index_detail_helpers';

const PERSONALIZATION_HELP_TOOLTIPS = [
	{
		triggerLabel: 'What personalization impact means',
		message: 'Controls how strongly personalization reorders matching results.'
	},
	{
		triggerLabel: 'What event scoring rows mean',
		message: 'Event rows map user behavior events to scores used by the strategy.'
	},
	{
		triggerLabel: 'What facet scoring rows mean',
		message: 'Facet rows weight profile facets that influence personalized ranking.'
	},
	{
		triggerLabel: 'What profile lookup userToken means',
		message: 'Lookup requires the same stable userToken sent with search and event requests.'
	}
] as const;

const DEFAULT_PERSONALIZATION_STRATEGY_JSON = JSON.stringify(
	{
		eventsScoring: [
			{ eventName: 'Product viewed', eventType: 'view', score: 10 },
			{ eventName: 'Product purchased', eventType: 'conversion', score: 50 }
		],
		facetsScoring: [
			{ facetName: 'brand', score: 70 },
			{ facetName: 'category', score: 30 }
		],
		personalizationImpact: 75
	},
	null,
	2
);

async function openStrategyEditor(page: Page, section: Locator): Promise<Locator> {
	const dialog = page.getByTestId('personalization-strategy-editor-dialog');
	await expect(async () => {
		if ((await dialog.count()) === 0) {
			await section.getByRole('button', { name: 'Edit Strategy' }).click();
		}
		await expect(dialog).toBeVisible();
	}).toPass({ timeout: 10_000 });
	return dialog;
}

test.describe('Personalization tab', () => {
	test.describe.configure({ timeout: 90_000 });

	test('renders explicit untouched and backend-error profile states', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-detail-personalization-error'
		);
		const section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		await expect(page.getByTestId('personalization-strategy-state-untouched')).toBeVisible();
		await assertSingleVisiblePersonalizationProfileState(
			page,
			'personalization-profile-state-untouched'
		);

		await section.getByPlaceholder('userToken').fill('');
		await section.getByRole('button', { name: 'Load Profile' }).click();
		await assertSingleVisiblePersonalizationProfileState(
			page,
			'personalization-profile-state-error'
		);
	});

	test('advanced-control tooltip shows audited personalization control help', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-detail-personalization-tooltips'
		);
		const section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');

		for (const tooltip of PERSONALIZATION_HELP_TOOLTIPS) {
			await section.getByRole('button', { name: tooltip.triggerLabel }).hover();
			await expect(page.getByRole('tooltip').filter({ hasText: tooltip.message })).toBeVisible();
		}
	});

	test('invalid personalization strategy shows recovery callout and copies example', async ({
		page,
		context,
		seedIndex,
		seedPersonalizationStrategy,
		readClipboardText,
		testRegion
	}) => {
		await context.grantPermissions(['clipboard-read', 'clipboard-write']);
		await page.addInitScript(() => {
			let clipboardText = '';
			Object.defineProperty(navigator, 'clipboard', {
				configurable: true,
				value: {
					writeText: async (text: string) => {
						clipboardText = text;
					},
					readText: async () => clipboardText
				}
			});
		});
		const indexName = await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-detail-personalization-invalid-strategy'
		);
		await seedPersonalizationStrategy(indexName, {
			eventsScoring: [{ eventName: '', eventType: 'view', score: 10 }],
			facetsScoring: [{ facetName: 'brand', score: 70 }],
			personalizationImpact: 75
		});

		await page.reload();
		const section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		const invalidState = section.getByTestId('personalization-strategy-invalid-state');
		await expect(invalidState).toContainText(
			'The saved personalization strategy could not be loaded.'
		);
		await expect(invalidState).toContainText(
			'The editor is showing a default strategy so you can repair and save a valid version.'
		);
		await expect(invalidState).not.toContainText('eventsScoring[0].eventName is required');
		await expect(section.getByTestId('personalization-strategy-save')).toBeDisabled();
		await expect(section.getByTestId('personalization-strategy-example-json')).toHaveText(
			DEFAULT_PERSONALIZATION_STRATEGY_JSON
		);

		const copyButton = section.getByRole('button', {
			name: 'Copy example personalization strategy'
		});
		await copyButton.click();
		await expect(section.getByTestId('personalization-strategy-copy-example')).toHaveText(
			'Example copied'
		);
		expect(await readClipboardText(page)).toBe(DEFAULT_PERSONALIZATION_STRATEGY_JSON);
	});

	test('shows loading and then a single empty profile branch after load and revisit', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(page, seedIndex, testRegion, 'e2e-detail-personalization-load');
		const section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		const userToken = `e2e-profile-${Date.now()}`;
		await section.getByPlaceholder('userToken').fill(userToken);
		await section.getByRole('button', { name: 'Load Profile' }).click();
		await expect(page.getByTestId('personalization-profile-state-loading')).toBeVisible();
		await assertSingleVisiblePersonalizationProfileState(
			page,
			'personalization-profile-state-empty'
		);

		await openIndexDetailTab(page, 'Settings', 'settings-section', false);
		await openIndexDetailTab(page, 'Personalization', 'personalization-section', false);
		await assertSingleVisiblePersonalizationProfileState(
			page,
			'personalization-profile-state-empty'
		);
	});

	test('renders the found profile branch after a successful lookup', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		const indexName = await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-detail-personalization-found'
		);
		const userToken = `e2e-profile-found-${Date.now()}`;
		const profileFixture = {
			userToken,
			lastEventAt: '2025-01-01T00:00:00.000Z',
			scores: {
				brand: { Nike: 0.5, Adidas: 0.1 },
				category: { Nike: 0.9, Running: 0.7 }
			}
		};
		const actionUrlPattern = new RegExp(
			`/console/indexes/${encodeURIComponent(indexName)}\\?/getPersonalizationProfile`
		);
		await page.route(actionUrlPattern, async (route) => {
			await route.fulfill({
				status: 200,
				contentType: 'application/json',
				body: JSON.stringify({
					type: 'success',
					status: 200,
					data: devalue.stringify({
						personalizationProfile: profileFixture,
						personalizationProfileLookupAttempted: true
					})
				})
			});
		});

		const section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		await section.getByPlaceholder('userToken').fill(userToken);
		await section.getByRole('button', { name: 'Load Profile' }).click();
		await assertSingleVisiblePersonalizationProfileState(
			page,
			'personalization-profile-state-found'
		);
		const foundState = page.getByTestId('personalization-profile-state-found');
		await expect(foundState.getByTestId('personalization-profile-user-token')).toHaveText(
			userToken
		);
		await expect(
			foundState.getByTestId('personalization-profile-metadata-row-user-token')
		).toContainText('User token');
		await expect(
			foundState.getByTestId('personalization-profile-metadata-row-last-event-at')
		).toContainText('Last event at');
		await expect(
			foundState.getByTestId('personalization-profile-metadata-value-last-event-at')
		).toHaveText('2025-01-01T00:00:00.000Z');

		const brandCategory = foundState.getByTestId(
			'personalization-profile-score-category-u6272616e64'
		);
		await expect(
			brandCategory.getByTestId('personalization-profile-score-category-title')
		).toHaveText('brand');
		await expect(
			brandCategory.getByTestId('personalization-profile-score-entry-u6272616e64-u4e696b65')
		).toContainText('Nike');
		await expect(
			brandCategory.getByTestId('personalization-profile-score-value-u6272616e64-u4e696b65')
		).toHaveText('0.5');
		await expect(
			brandCategory.getByTestId('personalization-profile-score-entry-u6272616e64-u416469646173')
		).toContainText('Adidas');
		await expect(
			brandCategory.getByTestId('personalization-profile-score-value-u6272616e64-u416469646173')
		).toHaveText('0.1');

		const categoryCategory = foundState.getByTestId(
			'personalization-profile-score-category-u63617465676f7279'
		);
		await expect(
			categoryCategory.getByTestId('personalization-profile-score-category-title')
		).toHaveText('category');
		await expect(
			categoryCategory.getByTestId(
				'personalization-profile-score-entry-u63617465676f7279-u4e696b65'
			)
		).toContainText('Nike');
		await expect(
			categoryCategory.getByTestId(
				'personalization-profile-score-value-u63617465676f7279-u4e696b65'
			)
		).toHaveText('0.9');
		await expect(
			categoryCategory.getByTestId(
				'personalization-profile-score-entry-u63617465676f7279-u52756e6e696e67'
			)
		).toContainText('Running');
		await expect(
			categoryCategory.getByTestId(
				'personalization-profile-score-value-u63617465676f7279-u52756e6e696e67'
			)
		).toHaveText('0.7');
		await expect(foundState.getByRole('button', { name: 'Delete Profile' })).toBeVisible();
	});

	test('strategy delete confirm keeps focus on cancel and persists delete across reload', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		let deleteStrategyPostCount = 0;
		page.on('request', (request) => {
			if (
				request.method() === 'POST' &&
				request.url().includes('?/deletePersonalizationStrategy')
			) {
				deleteStrategyPostCount += 1;
			}
		});

		const indexName = await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-detail-personalization-strategy-delete'
		);
		const section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		const deleteStrategyButton = section.getByRole('button', { name: 'Delete Strategy' });
		await deleteStrategyButton.click();

		const dialog = page.getByTestId('confirm-dialog');
		await expect(dialog).toBeVisible();
		await page.getByTestId('confirm-cancel-btn').click();
		await expect(dialog).toHaveCount(0);
		await expect(deleteStrategyButton).toBeFocused();
		expect(deleteStrategyPostCount).toBe(0);

		const strategyDeleteUrlPattern = new RegExp(
			`/console/indexes/${encodeURIComponent(indexName)}\\?/deletePersonalizationStrategy`
		);
		await page.route(strategyDeleteUrlPattern, async (route) => {
			await new Promise((resolve) => setTimeout(resolve, 300));
			await route.continue();
		});

		await deleteStrategyButton.click();
		await page.getByTestId('confirm-confirm-btn').click();
		await expect(dialog).toBeVisible();
		await expect(page.getByTestId('confirm-confirm-btn')).toBeDisabled();
		await expect(dialog).toHaveCount(0);
		await expect(page.getByTestId('shared-toast-mount').getByText('Strategy deleted.')).toBeVisible(
			{
				timeout: 10_000
			}
		);
		await expect(page.getByTestId('personalization-strategy-state-untouched')).toBeVisible();
		expect(deleteStrategyPostCount).toBe(1);

		await page.reload();
		await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		await expect(page.getByTestId('personalization-strategy-state-deleted')).toHaveCount(0);
		await expect(page.getByTestId('personalization-strategy-state-untouched')).toBeVisible();
	});

	test('profile delete confirm keeps no-op cancel, stays modal while confirming, and persists absence', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		let deleteProfilePostCount = 0;
		page.on('request', (request) => {
			if (request.method() === 'POST' && request.url().includes('?/deletePersonalizationProfile')) {
				deleteProfilePostCount += 1;
			}
		});

		const indexName = await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-detail-personalization-profile-delete'
		);
		const userToken = `e2e-profile-delete-${Date.now()}`;
		const profileFixture = {
			userToken,
			lastEventAt: '2025-01-01T00:00:00.000Z',
			scores: {
				brand: { Nike: 0.5 },
				category: { Running: 0.7 }
			}
		};
		let serveMockFoundProfile = true;
		const profileLookupUrlPattern = new RegExp(
			`/console/indexes/${encodeURIComponent(indexName)}\\?/getPersonalizationProfile`
		);
		await page.route(profileLookupUrlPattern, async (route) => {
			if (!serveMockFoundProfile) {
				await route.continue();
				return;
			}
			await route.fulfill({
				status: 200,
				contentType: 'application/json',
				body: JSON.stringify({
					type: 'success',
					status: 200,
					data: devalue.stringify({
						personalizationProfile: profileFixture,
						personalizationProfileLookupAttempted: true
					})
				})
			});
		});

		const section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		await section.getByPlaceholder('userToken').fill(userToken);
		await section.getByRole('button', { name: 'Load Profile' }).click();
		await assertSingleVisiblePersonalizationProfileState(
			page,
			'personalization-profile-state-found'
		);
		const foundState = page.getByTestId('personalization-profile-state-found');
		const deleteProfileButton = foundState.getByRole('button', { name: 'Delete Profile' });

		await deleteProfileButton.click();
		const dialog = page.getByTestId('confirm-dialog');
		await expect(dialog).toBeVisible();
		await page.getByTestId('confirm-cancel-btn').click();
		await expect(dialog).toHaveCount(0);
		await expect(deleteProfileButton).toBeFocused();
		expect(deleteProfilePostCount).toBe(0);
		await assertSingleVisiblePersonalizationProfileState(
			page,
			'personalization-profile-state-found'
		);

		serveMockFoundProfile = false;
		const profileDeleteUrlPattern = new RegExp(
			`/console/indexes/${encodeURIComponent(indexName)}\\?/deletePersonalizationProfile`
		);
		await page.route(profileDeleteUrlPattern, async (route) => {
			await new Promise((resolve) => setTimeout(resolve, 300));
			await route.continue();
		});

		await deleteProfileButton.click();
		await page.getByTestId('confirm-confirm-btn').click();
		await expect(dialog).toBeVisible();
		await expect(page.getByTestId('confirm-confirm-btn')).toBeDisabled();
		await expect(dialog).toHaveCount(0);
		await expect(page.getByTestId('shared-toast-mount').getByText('Profile deleted.')).toBeVisible({
			timeout: 10_000
		});
		await assertSingleVisiblePersonalizationProfileState(
			page,
			'personalization-profile-state-untouched'
		);
		expect(deleteProfilePostCount).toBe(1);

		await page.reload();
		const reloadedSection = await openIndexDetailTab(
			page,
			'Personalization',
			'personalization-section'
		);
		await reloadedSection.getByPlaceholder('userToken').fill(userToken);
		await reloadedSection.getByRole('button', { name: 'Load Profile' }).click();
		await openIndexDetailTab(page, 'Personalization', 'personalization-section', false);
		await assertSingleVisiblePersonalizationProfileState(
			page,
			'personalization-profile-state-empty'
		);
	});

	test('strategy editor gates invalid/unchanged saves and enforces 15-row caps', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		let saveStrategyPostCount = 0;
		page.on('request', (request) => {
			if (request.method() === 'POST' && request.url().includes('?/savePersonalizationStrategy')) {
				saveStrategyPostCount += 1;
			}
		});

		await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-detail-personalization-strategy-gating'
		);
		const section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		const strategySaveButton = section.getByTestId('personalization-strategy-save');
		await expect(strategySaveButton).toBeDisabled();

		await openStrategyEditor(page, section);

		await expect(
			page.getByTestId('editor-dialog-field-eventsScoring-0-eventType').locator('option')
		).toHaveCount(3);
		const eventTypeOptionValues = await page
			.getByTestId('editor-dialog-field-eventsScoring-0-eventType')
			.locator('option')
			.evaluateAll((options) =>
				options.map((option) => (option as HTMLOptionElement).value).sort()
			);
		expect(eventTypeOptionValues).toEqual(['click', 'conversion', 'view']);

		const addEventScoreRowButton = page.getByTestId('editor-dialog-add-eventsScoring');
		for (let index = 0; index < 13; index += 1) {
			await addEventScoreRowButton.click();
		}
		await expect(page.getByTestId(/editor-dialog-field-eventsScoring-\d+-eventName/)).toHaveCount(
			15
		);
		await expect(addEventScoreRowButton).toBeDisabled();

		const addFacetScoreRowButton = page.getByTestId('editor-dialog-add-facetsScoring');
		for (let index = 0; index < 13; index += 1) {
			await addFacetScoreRowButton.click();
		}
		await expect(page.getByTestId(/editor-dialog-field-facetsScoring-\d+-facetName/)).toHaveCount(
			15
		);
		await expect(addFacetScoreRowButton).toBeDisabled();

		await page.getByTestId('editor-dialog-field-eventsScoring-0-score').fill('101');
		await expect(page.getByTestId('editor-dialog-save')).toBeDisabled();
		await page.getByTestId('editor-dialog-field-eventsScoring-0-score').fill('10');
		await expect(async () => {
			await page
				.getByTestId('editor-dialog-field-eventsScoring-0-eventType')
				.selectOption('invalid-event-type', { timeout: 1_000 });
		}).rejects.toThrow();

		await page.getByTestId('editor-dialog-cancel').click();
		await expect(page.getByTestId('editor-dialog-discard')).toBeVisible();
		await page.getByTestId('editor-dialog-discard').click();
		await expect(page.getByTestId('personalization-strategy-editor-dialog')).toHaveCount(0);
		await expect(strategySaveButton).toBeDisabled();
		expect(saveStrategyPostCount).toBe(0);
	});

	test('strategy save persists across reload and rehydrates editor fields from server state', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-detail-personalization-strategy-persist'
		);
		let section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		const strategySaveButton = section.getByTestId('personalization-strategy-save');

		await openStrategyEditor(page, section);
		const impactInput = page.getByTestId('editor-dialog-field-personalizationImpact');
		const currentImpact = Number.parseInt(await impactInput.inputValue(), 10);
		const nextImpact = (currentImpact + 1) % 101;
		await impactInput.fill(String(nextImpact));
		await page.getByTestId('editor-dialog-save').click();
		await expect(page.getByTestId('personalization-strategy-editor-dialog')).toHaveCount(0);
		await expect(strategySaveButton).toBeEnabled();

		await strategySaveButton.click();
		await expect(page.getByTestId('shared-toast-mount').getByText('Strategy saved.')).toBeVisible({
			timeout: 10_000
		});
		await expect(page.getByTestId('personalization-strategy-state-untouched')).toBeVisible();

		await page.reload();
		section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		await openStrategyEditor(page, section);
		await expect(page.getByTestId('editor-dialog-field-personalizationImpact')).toHaveValue(
			String(nextImpact)
		);
		await page.getByTestId('editor-dialog-cancel').click();
	});

	test('strategy save survives tab switch and rehydrates editor from saved value', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-detail-personalization-strategy-tab-return'
		);
		let section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		const strategySaveButton = section.getByTestId('personalization-strategy-save');

		await openStrategyEditor(page, section);
		const impactInput = page.getByTestId('editor-dialog-field-personalizationImpact');
		const currentImpact = Number.parseInt(await impactInput.inputValue(), 10);
		const nextImpact = (currentImpact + 1) % 101;
		await impactInput.fill(String(nextImpact));
		await page.getByTestId('editor-dialog-save').click();
		await expect(page.getByTestId('personalization-strategy-editor-dialog')).toHaveCount(0);

		await expect(strategySaveButton).toBeEnabled();
		await strategySaveButton.click();
		await expect(page.getByTestId('shared-toast-mount').getByText('Strategy saved.')).toBeVisible({
			timeout: 10_000
		});
		await expect(page.getByTestId('personalization-strategy-state-untouched')).toBeVisible();

		await openIndexDetailTab(page, 'Settings', 'settings-section', false);
		section = await openIndexDetailTab(page, 'Personalization', 'personalization-section', false);
		await openStrategyEditor(page, section);
		await expect(page.getByTestId('editor-dialog-field-personalizationImpact')).toHaveValue(
			String(nextImpact)
		);
		await page.getByTestId('editor-dialog-cancel').click();
	});

	test('strategy submit renders explicit error state when server rejects payload', async ({
		page,
		seedIndex,
		testRegion
	}) => {
		await openSeededIndexDetailPage(
			page,
			seedIndex,
			testRegion,
			'e2e-detail-personalization-strategy-error'
		);
		const section = await openIndexDetailTab(page, 'Personalization', 'personalization-section');
		const saveButton = section.getByTestId('personalization-strategy-save');

		await openStrategyEditor(page, section);
		const impactInput = page.getByTestId('editor-dialog-field-personalizationImpact');
		const currentImpact = Number.parseInt(await impactInput.inputValue(), 10);
		const nextImpact = (currentImpact + 1) % 101;
		await impactInput.fill(String(nextImpact));
		await page.getByTestId('editor-dialog-save').click();
		await expect(saveButton).toBeEnabled();

		await section.getByTestId('personalization-strategy-save-form').evaluate((form) => {
			const strategyField = (form as HTMLFormElement).elements.namedItem(
				'strategy'
			) as HTMLInputElement | null;
			if (strategyField) {
				strategyField.value = '{"broken":true}';
			}
		});
		await saveButton.click();
		await expect(page.getByTestId('personalization-strategy-state-error')).toBeVisible();
	});
});
