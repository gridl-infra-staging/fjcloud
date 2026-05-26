import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent } from '@testing-library/svelte';
import type { ComponentProps } from 'svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

import RulesTab from './RulesTab.svelte';
import { sampleIndex, sampleRules } from '../detail.test.shared';

type RulesProps = ComponentProps<typeof RulesTab>;

function defaultProps(overrides: Partial<RulesProps> = {}): RulesProps {
	return {
		index: sampleIndex,
		rules: sampleRules,
		ruleError: '',
		ruleSaved: false,
		ruleDeleted: false,
		...overrides
	};
}

afterEach(cleanup);

describe('RulesTab', () => {
	describe('section shell', () => {
		it('renders the Rules heading and description', () => {
			render(RulesTab, { props: defaultProps() });

			expect(screen.getByText('Rules')).toBeInTheDocument();
			expect(screen.getByText(/create and manage ranking rules/i)).toBeInTheDocument();
		});

		it('sets data-testid and data-index on the section root', () => {
			const { container } = render(RulesTab, { props: defaultProps() });

			const section = container.querySelector('[data-testid="rules-section"]');
			expect(section).not.toBeNull();
			expect(section!.getAttribute('data-index')).toBe('products');
		});

		it('wires search form to URL query parameter with GET method', () => {
			const { container } = render(RulesTab, { props: defaultProps() });
			const searchForm = container.querySelector('form[action=""][method="GET"]');
			expect(searchForm).not.toBeNull();
			const queryInput = searchForm!.querySelector('input[name="q"]') as HTMLInputElement | null;
			expect(queryInput).not.toBeNull();
			const tabInput = searchForm!.querySelector('input[name="tab"]') as HTMLInputElement | null;
			expect(tabInput).not.toBeNull();
			expect(tabInput?.value).toBe('rules');
		});
	});

	describe('success and error banners', () => {
		it('shows saved banner when ruleSaved is true', () => {
			render(RulesTab, { props: defaultProps({ ruleSaved: true }) });
			expect(screen.getByText('Rule saved.')).toBeInTheDocument();
		});

		it('shows deleted banner when ruleDeleted is true', () => {
			render(RulesTab, { props: defaultProps({ ruleDeleted: true }) });
			expect(screen.getByText('Rule deleted.')).toBeInTheDocument();
		});

		it('shows error banner with error message', () => {
			render(RulesTab, { props: defaultProps({ ruleError: 'Invalid JSON' }) });
			expect(screen.getByText('Invalid JSON')).toBeInTheDocument();
		});

		it('does not show banners by default', () => {
			render(RulesTab, { props: defaultProps() });
			expect(screen.queryByText('Rule saved.')).not.toBeInTheDocument();
			expect(screen.queryByText('Rule deleted.')).not.toBeInTheDocument();
		});
	});

	describe('empty vs populated rules table', () => {
		it('shows empty state when rules list is empty', () => {
			render(RulesTab, {
				props: defaultProps({
					rules: { hits: [], nbHits: 0, page: 0, nbPages: 0 }
				})
			});
			expect(screen.getByText('No rules')).toBeInTheDocument();
		});

		it('renders rule row with objectID and description', () => {
			render(RulesTab, { props: defaultProps() });

			expect(screen.getByText('boost-shoes')).toBeInTheDocument();
			expect(screen.getByText('Boost shoes')).toBeInTheDocument();
		});

		it('renders results summary with unfiltered total from totalNbHits when provided', () => {
			render(RulesTab, {
				props: defaultProps({
					rules: {
						hits: [
							{
								objectID: 'boost-shoes',
								conditions: [],
								consequence: {},
								description: 'Boost shoes',
								enabled: true
							}
						],
						nbHits: 24,
						totalNbHits: 31,
						page: 0,
						nbPages: 3
					}
				})
			});

			expect(screen.getByText(/24 filtered results/i)).toBeInTheDocument();
			expect(screen.getByText(/31 total rules/i)).toBeInTheDocument();
		});

		it('renders filtered count from nbHits instead of current page size', () => {
			render(RulesTab, {
				props: defaultProps({
					rules: {
						hits: [
							{
								objectID: 'boost-shoes',
								conditions: [],
								consequence: {},
								description: 'Boost shoes',
								enabled: true
							}
						],
						nbHits: 24,
						totalNbHits: 128,
						page: 0,
						nbPages: 3
					}
				})
			});

			expect(screen.getByText(/24 filtered results/i)).toBeInTheDocument();
			expect(screen.getByText(/128 total rules/i)).toBeInTheDocument();
		});

		it('shows Enabled badge for enabled rules', () => {
			const { container } = render(RulesTab, { props: defaultProps() });

			// The header also says "Enabled", so scope to the badge span
			const badge = container.querySelector('[class*="bg-flapjack-mint/35"]');
			expect(badge).not.toBeNull();
			expect(badge!.textContent).toBe('Enabled');
		});

		it('shows Disabled badge for disabled rules', () => {
			render(RulesTab, {
				props: defaultProps({
					rules: {
						hits: [
							{
								objectID: 'disabled-rule',
								conditions: [],
								consequence: {},
								description: 'Disabled rule',
								enabled: false
							}
						],
						nbHits: 1,
						page: 0,
						nbPages: 1
					}
				})
			});
			expect(screen.getByText('Disabled')).toBeInTheDocument();
		});

		it('shows dash for rule with no description', () => {
			render(RulesTab, {
				props: defaultProps({
					rules: {
						hits: [
							{
								objectID: 'no-desc-rule',
								conditions: [],
								consequence: {}
							}
						],
						nbHits: 1,
						page: 0,
						nbPages: 1
					}
				})
			});
			expect(screen.getByText('-')).toBeInTheDocument();
		});

		it('renders table headers for objectID, Description, and Enabled', () => {
			render(RulesTab, { props: defaultProps() });

			expect(screen.getByText('objectID')).toBeInTheDocument();
			expect(screen.getByText('Description')).toBeInTheDocument();
			// "Enabled" appears both as header and badge — just check it's there
			expect(screen.getAllByText('Enabled').length).toBeGreaterThanOrEqual(1);
		});
	});

	describe('degraded state when rules fetch failed', () => {
		it('shows load-failure message when rules is null', () => {
			render(RulesTab, { props: defaultProps({ rules: null }) });
			expect(screen.getByText(/rules could not be loaded/i)).toBeInTheDocument();
		});

		it('does not show "No rules" empty state when rules is null', () => {
			render(RulesTab, { props: defaultProps({ rules: null }) });
			expect(screen.queryByText('No rules')).not.toBeInTheDocument();
		});

		it('keeps the rule creation affordance available when rules is null', () => {
			render(RulesTab, { props: defaultProps({ rules: null }) });
			expect(screen.getByRole('button', { name: /add rule/i })).toBeInTheDocument();
		});
	});

	describe('form contracts', () => {
		it('does not render rules JSON preview until dialog is open', async () => {
			render(RulesTab, { props: defaultProps() });

			expect(screen.queryByTestId('rules-editor-json-preview')).not.toBeInTheDocument();

			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));
			expect(screen.getByTestId('rules-editor-json-preview')).toBeInTheDocument();
		});

		it('renders rules custom controls inside the editor dialog container', async () => {
			render(RulesTab, { props: defaultProps() });
			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));

			const dialog = screen.getByRole('dialog');
			const preview = screen.getByTestId('rules-editor-json-preview');
			const promoteObjectInput = screen.getByLabelText(/promote item id/i);
			const promotePositionInput = screen.getByLabelText(/promote position/i);

			expect(dialog.contains(preview)).toBe(true);
			expect(dialog.contains(promoteObjectInput)).toBe(true);
			expect(dialog.contains(promotePositionInput)).toBe(true);
		});

		it('has saveRule form wired to ?/saveRule action', async () => {
			const { container } = render(RulesTab, { props: defaultProps() });
			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));

			const form = container.querySelector('form[action="?/saveRule"]');
			expect(form).not.toBeNull();
			expect(screen.getByRole('button', { name: /^create$/i })).toBeInTheDocument();
		});

		it('create mode keeps objectID editable', async () => {
			render(RulesTab, { props: defaultProps() });
			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));

			const objectIdInput = screen.getByLabelText(/object id/i);
			expect(objectIdInput).toBeInTheDocument();
			expect(objectIdInput).toBeEnabled();
		});

		it('has deleteRule form per rule row wired to ?/deleteRule action', () => {
			const { container } = render(RulesTab, { props: defaultProps() });

			const deleteForms = container.querySelectorAll('form[action="?/deleteRule"]');
			expect(deleteForms.length).toBe(1);

			const hiddenInput = deleteForms[0].querySelector(
				'input[name="objectID"]'
			) as HTMLInputElement;
			expect(hiddenInput.value).toBe('boost-shoes');
		});

		it('delete button has accessible label with rule objectID', () => {
			render(RulesTab, { props: defaultProps() });

			expect(screen.getByRole('button', { name: /delete rule boost-shoes/i })).toBeInTheDocument();
		});

		it('shows clear-all control only when rules exist', () => {
			const { rerender } = render(RulesTab, { props: defaultProps() });

			expect(screen.getByRole('button', { name: /clear all rules/i })).toBeInTheDocument();

			rerender(
				defaultProps({
					rules: { hits: [], nbHits: 0, page: 0, nbPages: 0 }
				})
			);

			expect(screen.queryByRole('button', { name: /clear all rules/i })).not.toBeInTheDocument();
		});

		it('edit mode keeps posted objectID immutable', async () => {
			const { container } = render(RulesTab, { props: defaultProps() });
			await fireEvent.click(screen.getByRole('button', { name: /edit rule boost-shoes/i }));

			expect(screen.queryByLabelText(/object id/i)).not.toBeInTheDocument();
			expect(screen.getByTestId('rules-editor-object-id-readonly').textContent).toBe('boost-shoes');
			await fireEvent.click(screen.getByRole('button', { name: /^save$/i }));

			const hiddenObjectIdInput = container.querySelector(
				'form[action="?/saveRule"] input[name="objectID"]'
			) as HTMLInputElement;
			expect(hiddenObjectIdInput.value).toBe('boost-shoes');
		});

		it('updates nested consequence fields and keeps payload bytes equal to preview', async () => {
			const { container } = render(RulesTab, { props: defaultProps() });
			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));

			await fireEvent.input(screen.getByLabelText(/object id/i), { target: { value: 'rule-123' } });
			await fireEvent.input(screen.getByLabelText(/description/i), {
				target: { value: 'Created from editor' }
			});
			await fireEvent.input(screen.getByLabelText(/promote item id/i), {
				target: { value: 'sku-1' }
			});
			await fireEvent.input(screen.getByLabelText(/promote position/i), {
				target: { value: '2' }
			});
			const preview = screen.getByTestId('rules-editor-json-preview');
			const previewBytes = preview.textContent;
			await fireEvent.click(screen.getByRole('button', { name: /^create$/i }));

			const hiddenRuleInput = container.querySelector(
				'form[action="?/saveRule"] input[name="rule"]'
			) as HTMLInputElement;
			const hiddenObjectIdInput = container.querySelector(
				'form[action="?/saveRule"] input[name="objectID"]'
			) as HTMLInputElement;

			expect(hiddenObjectIdInput.value).toBe('rule-123');
			expect(hiddenRuleInput.value).toBe(previewBytes);

			const postedRule = JSON.parse(hiddenRuleInput.value);
			expect(postedRule.consequence.promote).toEqual([{ objectID: 'sku-1', position: 2 }]);
		});

		it('keeps preview JSON synchronized with simple field edits before submit', async () => {
			render(RulesTab, { props: defaultProps() });
			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));

			await fireEvent.input(screen.getByLabelText(/object id/i), {
				target: { value: 'rule-live' }
			});
			await fireEvent.input(screen.getByLabelText(/description/i), {
				target: { value: 'Live preview description' }
			});
			await fireEvent.click(screen.getByLabelText(/enabled/i));

			const preview = screen.getByTestId('rules-editor-json-preview');
			const previewRule = JSON.parse(preview.textContent ?? '{}');

			expect(previewRule.objectID).toBe('rule-live');
			expect(previewRule.description).toBe('Live preview description');
			expect(previewRule.enabled).toBe(false);
		});

		it('keeps dialog interactive when conditions JSON is temporarily invalid', async () => {
			render(RulesTab, { props: defaultProps() });
			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));

			const conditionsInput = screen.getByLabelText(/conditions json/i) as HTMLTextAreaElement;
			await fireEvent.input(conditionsInput, { target: { value: '[' } });

			expect(screen.getByRole('button', { name: /^create$/i })).toBeInTheDocument();
			expect(screen.getByLabelText(/description/i)).toBeInTheDocument();
		});

		it('requires discard confirmation for consequence-only edits on cancel, backdrop, and escape', async () => {
			render(RulesTab, { props: defaultProps() });

			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));
			await fireEvent.input(screen.getByLabelText(/promote item id/i), {
				target: { value: 'sku-consequence-only' }
			});
			await fireEvent.click(screen.getByTestId('editor-dialog-cancel'));
			expect(screen.getByTestId('editor-dialog-discard')).toBeInTheDocument();
			await fireEvent.click(screen.getByTestId('editor-dialog-discard'));
			expect(screen.queryByRole('dialog')).not.toBeInTheDocument();

			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));
			await fireEvent.input(screen.getByLabelText(/promote item id/i), {
				target: { value: 'sku-consequence-only' }
			});
			await fireEvent.click(screen.getByTestId('editor-dialog-backdrop'));
			expect(screen.getByTestId('editor-dialog-discard')).toBeInTheDocument();
			await fireEvent.click(screen.getByTestId('editor-dialog-discard'));
			expect(screen.queryByRole('dialog')).not.toBeInTheDocument();

			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));
			await fireEvent.input(screen.getByLabelText(/promote item id/i), {
				target: { value: 'sku-consequence-only' }
			});
			await fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });
			expect(screen.getByTestId('editor-dialog-discard')).toBeInTheDocument();
		});

		it('keeps preview bytes stable when consequence fields change during invalid conditions draft', async () => {
			render(RulesTab, { props: defaultProps() });
			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));

			const previewBeforeInvalidJson = screen.getByTestId('rules-editor-json-preview').textContent;
			await fireEvent.input(screen.getByLabelText(/conditions json/i), { target: { value: '[' } });
			expect(screen.getByRole('alert')).toHaveTextContent('Conditions JSON must be valid JSON.');

			await fireEvent.input(screen.getByLabelText(/promote item id/i), {
				target: { value: 'sku-2' }
			});
			await fireEvent.input(screen.getByLabelText(/promote position/i), { target: { value: '5' } });

			expect(screen.getByTestId('rules-editor-json-preview').textContent).toBe(
				previewBeforeInvalidJson
			);
		});

		it('reseeds create mode draft after close and reopen', async () => {
			render(RulesTab, { props: defaultProps() });
			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));

			await fireEvent.input(screen.getByLabelText(/object id/i), {
				target: { value: 'stale-object-id' }
			});
			await fireEvent.input(screen.getByLabelText(/description/i), {
				target: { value: 'Stale description' }
			});

			await fireEvent.click(screen.getByTestId('editor-dialog-cancel'));
			await fireEvent.click(screen.getByTestId('editor-dialog-discard'));
			await fireEvent.click(screen.getByRole('button', { name: /add rule/i }));

			const reopenedObjectId = screen.getByLabelText(/object id/i) as HTMLInputElement;
			const reopenedDescription = screen.getByLabelText(/description/i) as HTMLInputElement;
			const reopenedPreview = JSON.parse(
				screen.getByTestId('rules-editor-json-preview').textContent ?? '{}'
			);

			expect(reopenedObjectId.value).toMatch(/^rule-/);
			expect(reopenedObjectId.value).not.toBe('stale-object-id');
			expect(reopenedDescription.value).toBe('');
			expect(reopenedPreview.objectID).toBe(reopenedObjectId.value);
			expect(reopenedPreview.description).toBe('');
		});

		it('reseeds edit mode draft after close and reopen of same rule target', async () => {
			render(RulesTab, { props: defaultProps() });
			await fireEvent.click(screen.getByRole('button', { name: /edit rule boost-shoes/i }));

			await fireEvent.input(screen.getByLabelText(/description/i), {
				target: { value: 'Mutated draft description' }
			});

			await fireEvent.click(screen.getByTestId('editor-dialog-cancel'));
			await fireEvent.click(screen.getByTestId('editor-dialog-discard'));
			await fireEvent.click(screen.getByRole('button', { name: /edit rule boost-shoes/i }));

			const reopenedDescription = screen.getByLabelText(/description/i) as HTMLInputElement;
			const reopenedPreview = JSON.parse(
				screen.getByTestId('rules-editor-json-preview').textContent ?? '{}'
			);

			expect(reopenedDescription.value).toBe('Boost shoes');
			expect(reopenedPreview.description).toBe('Boost shoes');
		});

		it('surfaces action-level ruleError failures', () => {
			render(RulesTab, { props: defaultProps({ ruleError: 'save failed on server' }) });
			expect(screen.getByText('save failed on server')).toBeInTheDocument();
		});
	});
});
