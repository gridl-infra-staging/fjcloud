import { test, expect } from '../../fixtures/fixtures';

test.describe('Rules fixture contracts', () => {
	test.use({ permissions: ['clipboard-read', 'clipboard-write'] });

	test('backend rule helpers provide value-correct lifecycle assertions', async ({
		page,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		seedRules,
		getRule,
		searchRules
	}) => {
		const customer = await arrangeTrackedCustomerSession(page, {
			emailPrefix: 'e2e-rules-fixture'
		});
		const indexName = `e2e-rules-fixture-${Date.now()}`;
		const ruleObjectId = `rule-${Date.now()}`;
		const rulePayload = {
			objectID: ruleObjectId,
			conditions: [{ pattern: 'fixture-contract-pattern', anchoring: 'contains' }],
			consequence: {
				params: {
					filters: 'tier:gold'
				}
			},
			description: 'fixture-owned rule payload',
			enabled: true
		};

		await seedCustomerIndex(customer, indexName);
		await seedRules(indexName, [rulePayload]);

		const fetchedRule = await getRule(indexName, ruleObjectId);
		expect(fetchedRule.objectID).toBe(ruleObjectId);
		expect(fetchedRule.description).toBe('fixture-owned rule payload');
		expect(fetchedRule.enabled).toBe(true);
		expect(fetchedRule.conditions[0]?.pattern).toBe('fixture-contract-pattern');
		expect(fetchedRule.consequence.params?.filters).toBe('tier:gold');

		const searchResult = await searchRules(indexName, 'fixture-contract-pattern', 0, 10);
		expect(searchResult.nbHits).toBeGreaterThan(0);
		expect(searchResult.page).toBe(0);
		expect(searchResult.nbPages).toBeGreaterThan(0);
		expect(searchResult.hits.some((hit) => hit.objectID === ruleObjectId)).toBe(true);
		const searchedRule = searchResult.hits.find((hit) => hit.objectID === ruleObjectId);
		expect(searchedRule?.description).toBe('fixture-owned rule payload');
		expect(searchedRule?.enabled).toBe(true);
		expect(searchedRule?.conditions[0]?.anchoring).toBe('contains');
		expect(searchedRule?.consequence.params?.filters).toBe('tier:gold');
	});

	test('clipboard reads only through fixture helper after write', async ({
		context,
		page,
		readClipboardText
	}) => {
		await context.grantPermissions(['clipboard-read', 'clipboard-write']);
		await page.goto('/console');

		const clipboardPayload = `rules-fixture-clipboard-${Date.now()}`;
		await page.evaluate(async (text) => {
			await navigator.clipboard.writeText(text);
		}, clipboardPayload);

		const clipboardText = await readClipboardText(page);
		expect(clipboardText).toBe(clipboardPayload);
	});
});
