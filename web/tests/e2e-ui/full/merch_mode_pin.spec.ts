import { test, expect, type CreatedFixtureUser } from '../../fixtures/fixtures';
import {
	gotoIndexDetailWithRetry,
	SEARCH_PANEL_TEST_ID,
	SEARCH_TAB_LABEL,
	submitSearchPreviewQuery,
	waitForSearchPreviewHitsToContain,
	waitForSearchPreviewReady
} from '../../fixtures/search-preview-helpers';
import { seedSearchableIndexForCustomer } from '../../fixtures/searchable-index';

const API_URL = process.env.API_URL ?? 'http://localhost:3001';

test.use({ storageState: { cookies: [], origins: [] } });

const MERCH_PIN_DOCUMENTS = [
	{
		objectID: 'merch-pin-doc-1',
		title: 'Rust Programming Language',
		body: 'Systems programming with Rust',
		category: 'language'
	},
	{
		objectID: 'merch-pin-doc-2',
		title: 'Rust Async Book',
		body: 'Futures and async/await in Rust',
		category: 'systems'
	},
	{
		objectID: 'merch-pin-doc-3',
		title: 'Rust Web Framework',
		body: 'Building web apps with Rust',
		category: 'web'
	},
	{
		objectID: 'merch-pin-doc-4',
		title: 'Rust Embedded Systems',
		body: 'Embedded development with Rust',
		category: 'embedded'
	},
	{
		objectID: 'merch-pin-doc-5',
		title: 'TypeScript Handbook',
		body: 'JavaScript with types',
		category: 'tech'
	}
];

let activeCustomer: CreatedFixtureUser;

test.describe('Merch mode pin writes rule @merch_mode_pin', () => {
	test.describe.configure({ timeout: 180_000 });

	test.beforeEach(async ({ page, arrangeTrackedCustomerSession }) => {
		activeCustomer = await arrangeTrackedCustomerSession(page, {
			emailPrefix: 'e2e-merch-pin'
		});
	});

	test('pin from search preview creates a rule visible in merchandising tab', async ({
		page,
		testRegion
	}) => {
		const seed = Date.now();
		const indexName = `e2e-merch-pin-${seed}`;

		await seedSearchableIndexForCustomer({
			apiUrl: API_URL,
			adminKey: process.env.E2E_ADMIN_KEY,
			customerId: activeCustomer.customerId,
			token: activeCustomer.token,
			name: indexName,
			region: testRegion,
			query: 'Rust',
			expectedHitText: 'Rust Programming Language',
			documents: MERCH_PIN_DOCUMENTS
		});

		await gotoIndexDetailWithRetry(page, indexName);
		await page.getByRole('tab', { name: SEARCH_TAB_LABEL }).click();
		await expect(page.getByTestId(SEARCH_PANEL_TEST_ID)).toBeVisible();
		await waitForSearchPreviewReady(page);
		await submitSearchPreviewQuery(page, 'Rust');
		await waitForSearchPreviewHitsToContain(page, 'Rust Programming Language', 60_000);

		const merchToggle = page.getByRole('checkbox', { name: 'Merchandising mode' });
		await merchToggle.check();
		await expect(merchToggle).toBeChecked();

		const firstCard = page.getByTestId('document-card').first();
		const pinPositionInput = firstCard.getByTestId('card-merch-pin-position');
		await pinPositionInput.fill('3');

		await firstCard.getByTestId('card-merch-pin').click();

		await expect(page.getByLabel('Notifications').getByText(/pinned|rule.*created/i)).toBeVisible({
			timeout: 15_000
		});

		await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=merchandising`);
		await expect(page.getByTestId('merchandising-section')).toBeVisible({ timeout: 15_000 });

		const ruleRow = page
			.getByTestId('merchandising-section')
			.getByTestId(/^merchandising-rule-row-/);
		await expect(ruleRow.first()).toBeVisible({ timeout: 15_000 });
		await expect(ruleRow.first()).toContainText('Rust');
	});
});
