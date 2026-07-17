import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within, fireEvent } from '@testing-library/svelte';
import type { ComponentProps } from 'svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

import MerchandisingTab from './MerchandisingTab.svelte';
import { sampleIndex, sampleRules } from '../detail.test.shared';
import { buildRuleDescription } from '$lib/rules/ruleHelpers';
import type { Index, Rule, RuleSearchResponse } from '$lib/api/types';

type FutureRuleSearchResponse = RuleSearchResponse & {
	totalNbHits?: number;
	query?: string;
};

interface FutureMerchandisingProps {
	index: Index;
	rules: FutureRuleSearchResponse | null;
	ruleError: string;
	ruleSaved: boolean;
	ruleDeleted: boolean;
	rulesCleared: boolean;
	rulesClearError: string;
}

function defaultProps(overrides: Partial<FutureMerchandisingProps> = {}): FutureMerchandisingProps {
	return {
		index: sampleIndex,
		rules: sampleRules,
		ruleError: '',
		ruleSaved: false,
		ruleDeleted: false,
		rulesCleared: false,
		rulesClearError: '',
		...overrides
	};
}

function renderMerchandising(overrides: Partial<FutureMerchandisingProps> = {}) {
	return render(MerchandisingTab, {
		props: defaultProps(overrides) as unknown as ComponentProps<typeof MerchandisingTab>
	});
}

function ruleRow(container: HTMLElement, objectID: string): HTMLElement {
	const row = container.querySelector(`[data-testid="merchandising-rule-row-${objectID}"]`);
	expect(row).not.toBeNull();
	return row as HTMLElement;
}

function rule(overrides: Partial<Rule>): Rule {
	return {
		objectID: 'rule',
		conditions: [{ pattern: 'shoes', anchoring: 'contains' }],
		consequence: {},
		description: '',
		enabled: true,
		...overrides
	};
}

function postedSaveRule(container: HTMLElement): { objectID: string; rule: Rule } {
	const saveForms = Array.from(container.querySelectorAll('form[action="?/saveRule"]'));
	const dialogSaveForm = saveForms.at(-1);
	const hiddenObjectIdInput = dialogSaveForm?.querySelector(
		'input[name="objectID"]'
	) as HTMLInputElement | null;
	const hiddenRuleInput = dialogSaveForm?.querySelector(
		'input[name="rule"]'
	) as HTMLInputElement | null;

	expect(hiddenObjectIdInput).not.toBeNull();
	expect(hiddenRuleInput).not.toBeNull();

	return {
		objectID: hiddenObjectIdInput!.value,
		rule: JSON.parse(hiddenRuleInput!.value) as Rule
	};
}

function epochSecondsForDatetimeLocal(datetimeLocal: string): number {
	const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(datetimeLocal);
	expect(match).not.toBeNull();
	const [, year, month, day, hour, minute] = match!;
	return (
		new Date(
			Number.parseInt(year, 10),
			Number.parseInt(month, 10) - 1,
			Number.parseInt(day, 10),
			Number.parseInt(hour, 10),
			Number.parseInt(minute, 10),
			0,
			0
		).getTime() / 1000
	);
}

async function inputByLabel(label: RegExp, value: string): Promise<void> {
	await fireEvent.input(screen.getByLabelText(label), { target: { value } });
}

async function changeByLabel(label: RegExp, value: string): Promise<void> {
	await fireEvent.change(screen.getByLabelText(label), { target: { value } });
}

afterEach(cleanup);

describe('MerchandisingTab', () => {
	describe('section shell', () => {
		it('renders the hub shell and new-rule affordance for the index', () => {
			const { container } = renderMerchandising();

			const section = container.querySelector('[data-testid="merchandising-section"]');
			expect(section).not.toBeNull();
			expect(section!.getAttribute('data-index')).toBe('products');
			expect(screen.getByRole('heading', { name: 'Merchandising hub' })).toBeInTheDocument();
			expect(screen.getByRole('button', { name: '+ New rule' })).toBeInTheDocument();
		});

		it('does not render the old search-and-pin merchandising canvas', () => {
			const { container } = renderMerchandising();

			expect(container.querySelector('form[action="?/search"]')).toBeNull();
			expect(screen.queryByPlaceholderText('Enter a search query')).not.toBeInTheDocument();
			expect(screen.queryByRole('button', { name: /^Pin\b/i })).not.toBeInTheDocument();
			expect(screen.queryByRole('button', { name: /^Hide\b/i })).not.toBeInTheDocument();
			expect(screen.queryByRole('button', { name: 'Save as Rule' })).not.toBeInTheDocument();
		});

		it('preserves the existing rules GET filter path with q and tab state', () => {
			const { container } = renderMerchandising({
				rules: {
					...sampleRules,
					query: 'winter boots'
				}
			});

			const searchForm = container.querySelector('form[action=""][method="GET"]');
			expect(searchForm).not.toBeNull();

			const queryInput = searchForm!.querySelector('input[name="q"]') as HTMLInputElement | null;
			const tabInput = searchForm!.querySelector('input[name="tab"]') as HTMLInputElement | null;
			expect(queryInput).not.toBeNull();
			expect(queryInput!.value).toBe('winter boots');
			expect(tabInput).not.toBeNull();
			expect(tabInput!.value).toBe('merchandising');
		});

		it('shows the v1 no-stats placeholder with decided copy', () => {
			renderMerchandising();

			expect(
				screen.getByText('Merchandising performance stats are not available yet.')
			).toBeInTheDocument();
		});
	});

	describe('rules list', () => {
		it('renders rule rows from rules.hits in API order with objectID and owned description copy', () => {
			const firstRule = rule({
				objectID: 'boost-shoes',
				conditions: [{ pattern: 'shoes', anchoring: 'contains' }],
				consequence: { promote: [{ objectID: 'shoe-1', position: 0 }] },
				description: 'Fixture description should not own row summary'
			});
			const secondRule = rule({
				objectID: 'hide-sandals',
				conditions: [{ pattern: 'sandals', anchoring: 'is' }],
				consequence: { hide: [{ objectID: 'sandal-9' }] },
				description: 'Another fixture description'
			});
			const { container } = renderMerchandising({
				rules: { hits: [firstRule, secondRule], nbHits: 2, page: 0, nbPages: 1 }
			});

			const rows = Array.from(
				container.querySelectorAll('[data-testid^="merchandising-rule-row-"]')
			);
			expect(rows).toHaveLength(2);
			expect(rows.map((row) => row.getAttribute('data-testid'))).toEqual([
				'merchandising-rule-row-boost-shoes',
				'merchandising-rule-row-hide-sandals'
			]);
			expect(rows[0]).toHaveTextContent('boost-shoes');
			expect(rows[0]).toHaveTextContent(buildRuleDescription(firstRule));
			expect(rows[1]).toHaveTextContent('hide-sandals');
			expect(rows[1]).toHaveTextContent(buildRuleDescription(secondRule));
		});

		it('renders disabled rules as Draft without adding the draft badge to enabled rules', () => {
			const enabledRule = rule({ objectID: 'enabled-rule', enabled: true });
			const draftRule = rule({ objectID: 'draft-rule', enabled: false });
			const { container } = renderMerchandising({
				rules: { hits: [enabledRule, draftRule], nbHits: 2, page: 0, nbPages: 1 }
			});

			expect(within(ruleRow(container, 'draft-rule')).getByText('Draft')).toBeInTheDocument();
			expect(
				within(ruleRow(container, 'enabled-rule')).queryByText('Draft')
			).not.toBeInTheDocument();
		});

		it('shows the hub empty state while keeping rule creation available', () => {
			renderMerchandising({ rules: { hits: [], nbHits: 0, page: 0, nbPages: 0 } });

			expect(screen.getByText('No merchandising rules yet')).toBeInTheDocument();
			expect(
				screen.getByText('Create rules to promote, hide, or pin records for this index.')
			).toBeInTheDocument();
			expect(screen.getByRole('button', { name: '+ New rule' })).toBeInTheDocument();
		});

		it('shows a filtered-empty state instead of the empty-index copy when the filter hides every rule', () => {
			renderMerchandising({
				rules: {
					hits: [],
					nbHits: 0,
					totalNbHits: 5,
					page: 0,
					nbPages: 0,
					query: 'no-such-term'
				}
			});

			expect(screen.getByText('No rules match your search')).toBeInTheDocument();
			expect(screen.queryByText('No merchandising rules yet')).not.toBeInTheDocument();
			expect(
				screen.queryByText('Create rules to promote, hide, or pin records for this index.')
			).not.toBeInTheDocument();
		});

		it('shows load-failure copy while keeping rule creation available when rules are unavailable', () => {
			renderMerchandising({ rules: null });

			expect(screen.getByText('Merchandising rules could not be loaded.')).toBeInTheDocument();
			expect(screen.queryByText('No merchandising rules yet')).not.toBeInTheDocument();
			expect(screen.getByRole('button', { name: '+ New rule' })).toBeInTheDocument();
		});

		it('renders filtered and total rule counts from the rules response', () => {
			renderMerchandising({
				rules: {
					hits: [rule({ objectID: 'boost-shoes' })],
					nbHits: 24,
					totalNbHits: 31,
					page: 0,
					nbPages: 3
				}
			});

			expect(screen.getByText('24 filtered rules')).toBeInTheDocument();
			expect(screen.getByText('31 total rules')).toBeInTheDocument();
		});

		it('uses nbHits for the filtered count instead of current page size', () => {
			renderMerchandising({
				rules: {
					hits: [rule({ objectID: 'boost-shoes' })],
					nbHits: 24,
					totalNbHits: 128,
					page: 0,
					nbPages: 3
				}
			});

			expect(screen.getByText('24 filtered rules')).toBeInTheDocument();
			expect(screen.getByText('128 total rules')).toBeInTheDocument();
		});
	});

	describe('persistence forms', () => {
		it('opens a declarative builder instead of conditions or validity JSON authoring', async () => {
			renderMerchandising();

			await fireEvent.click(screen.getByRole('button', { name: '+ New rule' }));

			const dialog = screen.getByRole('dialog');
			expect(within(dialog).getByLabelText(/object id/i)).toBeInTheDocument();
			expect(within(dialog).getByLabelText(/query pattern/i)).toBeInTheDocument();
			expect(within(dialog).getByLabelText(/anchoring mode/i)).toBeInTheDocument();
			expect(within(dialog).getByLabelText(/filter scope/i)).toBeInTheDocument();
			expect(within(dialog).getByLabelText(/promote item id/i)).toBeInTheDocument();
			expect(within(dialog).getByLabelText(/promote position/i)).toHaveAttribute('min', '1');
			expect(within(dialog).getByLabelText(/valid from/i)).toHaveAttribute(
				'type',
				'datetime-local'
			);
			expect(within(dialog).getByLabelText(/valid until/i)).toHaveAttribute(
				'type',
				'datetime-local'
			);
			expect(within(dialog).getByLabelText(/rule state/i)).toBeInTheDocument();
			expect(within(dialog).queryByLabelText(/conditions json/i)).not.toBeInTheDocument();
			expect(within(dialog).queryByLabelText(/validity json/i)).not.toBeInTheDocument();
		});

		it('creates draft rules through the existing saveRule form with a structured rule payload', async () => {
			const { container } = renderMerchandising({
				rules: { hits: [], nbHits: 0, page: 0, nbPages: 0 }
			});

			await fireEvent.click(screen.getByRole('button', { name: '+ New rule' }));
			await inputByLabel(/object id/i, 'summer-draft');
			await inputByLabel(/description/i, 'Summer ranking draft');
			await inputByLabel(/query pattern/i, '  summer shoes  ');
			await changeByLabel(/anchoring mode/i, 'contains');
			await inputByLabel(/filter scope/i, '   ');
			await inputByLabel(/promote item id/i, 'sku-summer-1');
			await inputByLabel(/promote position/i, '3');
			await inputByLabel(/valid from/i, '2026-07-01T10:30');
			await inputByLabel(/valid until/i, '2026-07-31T21:45');
			await changeByLabel(/rule state/i, 'draft');

			await fireEvent.click(screen.getByRole('button', { name: /^create$/i }));

			expect(postedSaveRule(container)).toEqual({
				objectID: 'summer-draft',
				rule: {
					objectID: 'summer-draft',
					description: 'Summer ranking draft',
					conditions: [{ pattern: 'summer shoes', anchoring: 'contains' }],
					consequence: { promote: [{ objectID: 'sku-summer-1', position: 3 }] },
					validity: [
						{
							from: epochSecondsForDatetimeLocal('2026-07-01T10:30'),
							until: epochSecondsForDatetimeLocal('2026-07-31T21:45')
						}
					],
					enabled: false
				}
			});
		});

		it('edits seeded draft rules without changing objectID or dropping existing payload fields', async () => {
			const initialDraft = rule({
				objectID: 'draft-shoes',
				description: 'Draft shoe promotion',
				conditions: [{ pattern: 'shoes', anchoring: 'contains', filters: 'brand:Nike' }],
				consequence: { promote: [{ objectID: 'sku-9', position: 4 }] },
				validity: [
					{
						from: epochSecondsForDatetimeLocal('2026-08-01T00:00'),
						until: epochSecondsForDatetimeLocal('2026-08-15T23:30')
					}
				],
				enabled: false
			});
			const { container } = renderMerchandising({
				rules: { hits: [initialDraft], nbHits: 1, page: 0, nbPages: 1 }
			});

			await fireEvent.click(screen.getByRole('button', { name: /edit rule draft-shoes/i }));

			expect(screen.queryByLabelText(/object id/i)).not.toBeInTheDocument();
			expect(screen.getByTestId('rules-editor-object-id-readonly')).toHaveTextContent(
				'draft-shoes'
			);
			expect(screen.getByLabelText(/description/i)).toHaveValue('Draft shoe promotion');
			expect(screen.getByLabelText(/query pattern/i)).toHaveValue('shoes');
			expect(screen.getByLabelText(/anchoring mode/i)).toHaveValue('contains');
			expect(screen.getByLabelText(/filter scope/i)).toHaveValue('brand:Nike');
			expect(screen.getByLabelText(/promote item id/i)).toHaveValue('sku-9');
			expect(screen.getByLabelText(/promote position/i)).toHaveValue(4);
			expect(screen.getByLabelText(/valid from/i)).toHaveValue('2026-08-01T00:00');
			expect(screen.getByLabelText(/valid until/i)).toHaveValue('2026-08-15T23:30');
			expect(screen.getByLabelText(/rule state/i)).toHaveValue('draft');

			await inputByLabel(/description/i, 'Edited draft shoe promotion');
			await inputByLabel(/promote position/i, '5');
			await fireEvent.click(screen.getByRole('button', { name: /^save$/i }));

			expect(postedSaveRule(container)).toEqual({
				objectID: 'draft-shoes',
				rule: {
					...initialDraft,
					description: 'Edited draft shoe promotion',
					consequence: { promote: [{ objectID: 'sku-9', position: 5 }] }
				}
			});
		});

		it('publishes draft rows through saveRule while preserving the draft payload except enabled', async () => {
			const draftRule = rule({
				objectID: 'draft-publish',
				description: 'Ready draft',
				conditions: [{ pattern: 'boots', anchoring: 'contains', filters: 'season:winter' }],
				consequence: { promote: [{ objectID: 'sku-boot-1', position: 2 }] },
				validity: [
					{
						from: epochSecondsForDatetimeLocal('2026-11-01T00:00'),
						until: epochSecondsForDatetimeLocal('2026-12-31T23:59')
					}
				],
				enabled: false
			});
			const { container } = renderMerchandising({
				rules: { hits: [draftRule], nbHits: 1, page: 0, nbPages: 1 }
			});

			await fireEvent.click(screen.getByRole('button', { name: /publish rule draft-publish/i }));

			const row = ruleRow(container, 'draft-publish');
			const hiddenObjectID = row.querySelector(
				'form[action="?/saveRule"] input[name="objectID"]'
			) as HTMLInputElement | null;
			const hiddenRule = row.querySelector(
				'form[action="?/saveRule"] input[name="rule"]'
			) as HTMLInputElement | null;

			expect(hiddenObjectID).not.toBeNull();
			expect(hiddenObjectID!.value).toBe('draft-publish');
			expect(JSON.parse(hiddenRule!.value)).toEqual({ ...draftRule, enabled: true });
		});

		it('creates rules through the existing saveRule action from the hub dialog', async () => {
			const { container } = renderMerchandising();

			expect(screen.queryByTestId('rules-editor-json-preview')).not.toBeInTheDocument();

			await fireEvent.click(screen.getByRole('button', { name: '+ New rule' }));

			const dialog = screen.getByRole('dialog');
			const preview = screen.getByTestId('rules-editor-json-preview');
			const promoteObjectInput = screen.getByLabelText(/promote item id/i);
			const promotePositionInput = screen.getByLabelText(/promote position/i);
			expect(dialog.contains(preview)).toBe(true);
			expect(dialog.contains(promoteObjectInput)).toBe(true);
			expect(dialog.contains(promotePositionInput)).toBe(true);

			await fireEvent.input(screen.getByLabelText(/object id/i), {
				target: { value: 'rule-123' }
			});
			await fireEvent.input(screen.getByLabelText(/description/i), {
				target: { value: 'Created from editor' }
			});
			await fireEvent.input(promoteObjectInput, { target: { value: 'sku-1' } });
			await fireEvent.input(promotePositionInput, { target: { value: '2' } });

			const previewBytes = preview.textContent;
			await fireEvent.click(screen.getByRole('button', { name: /^create$/i }));

			const hiddenObjectIdInput = container.querySelector(
				'form[action="?/saveRule"] input[name="objectID"]'
			) as HTMLInputElement | null;
			const hiddenRuleInput = container.querySelector(
				'form[action="?/saveRule"] input[name="rule"]'
			) as HTMLInputElement | null;
			expect(hiddenObjectIdInput).not.toBeNull();
			expect(hiddenObjectIdInput!.value).toBe('rule-123');
			expect(hiddenRuleInput).not.toBeNull();
			expect(hiddenRuleInput!.value).toBe(previewBytes);

			const postedRule = JSON.parse(hiddenRuleInput!.value);
			expect(postedRule.consequence.promote).toEqual([{ objectID: 'sku-1', position: 2 }]);
		});

		it('deletes each row through the existing deleteRule action with hidden objectID', () => {
			const { container } = renderMerchandising();

			const form = ruleRow(container, 'boost-shoes').querySelector('form[action="?/deleteRule"]');
			expect(form).not.toBeNull();
			const hiddenObjectID = form!.querySelector('input[name="objectID"]') as HTMLInputElement;
			expect(hiddenObjectID).not.toBeNull();
			expect(hiddenObjectID.value).toBe('boost-shoes');
		});

		it('shows the existing clearRules control only when rules exist', () => {
			const { container, rerender } = renderMerchandising();

			expect(container.querySelector('form[action="?/clearRules"]')).not.toBeNull();
			expect(screen.getByRole('button', { name: /clear all rules/i })).toBeInTheDocument();

			rerender(
				defaultProps({
					rules: { hits: [], nbHits: 0, page: 0, nbPages: 0 }
				}) as unknown as ComponentProps<typeof MerchandisingTab>
			);

			expect(container.querySelector('form[action="?/clearRules"]')).toBeNull();
			expect(screen.queryByRole('button', { name: /clear all rules/i })).not.toBeInTheDocument();
		});

		it('surfaces clearRules success and error feedback through the hub', () => {
			const { rerender } = renderMerchandising({ rulesCleared: true });

			expect(screen.getByText('Rules cleared.')).toBeInTheDocument();
			expect(screen.queryByText('Failed to clear rules')).not.toBeInTheDocument();

			rerender(
				defaultProps({
					rulesCleared: false,
					rulesClearError: 'Failed to clear rules'
				}) as unknown as ComponentProps<typeof MerchandisingTab>
			);

			expect(screen.queryByText('Rules cleared.')).not.toBeInTheDocument();
			expect(screen.getByText('Failed to clear rules')).toBeInTheDocument();
		});
	});

	describe('conflict warnings', () => {
		it('warns only rows with matching normalized query rule scope', () => {
			const firstConflict = rule({
				objectID: 'conflict-one',
				conditions: [{ pattern: '  SHOES ', anchoring: 'contains', filters: 'brand: Nike ' }]
			});
			const secondConflict = rule({
				objectID: 'conflict-two',
				conditions: [{ pattern: 'shoes', anchoring: ' contains ', filters: ' BRAND: nike' }]
			});
			const nearbyRule = rule({
				objectID: 'nearby-rule',
				conditions: [{ pattern: 'shoes', anchoring: 'contains', filters: 'brand: adidas' }]
			});
			const { container } = renderMerchandising({
				rules: {
					hits: [firstConflict, secondConflict, nearbyRule],
					nbHits: 3,
					page: 0,
					nbPages: 1
				}
			});
			const warning = 'Conflicts with another rule for this query and filter scope';

			expect(within(ruleRow(container, 'conflict-one')).getByText(warning)).toBeInTheDocument();
			expect(within(ruleRow(container, 'conflict-two')).getByText(warning)).toBeInTheDocument();
			expect(
				within(ruleRow(container, 'nearby-rule')).queryByText(warning)
			).not.toBeInTheDocument();
		});
	});
});
