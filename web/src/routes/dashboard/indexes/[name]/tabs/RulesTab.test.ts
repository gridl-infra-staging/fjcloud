import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
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

		it('shows Enabled badge for enabled rules', () => {
			const { container } = render(RulesTab, { props: defaultProps() });

			// The header also says "Enabled", so scope to the badge span
			const badge = container.querySelector('.bg-green-100');
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

		it('keeps the add/update form available when rules is null', () => {
			const { container } = render(RulesTab, { props: defaultProps({ rules: null }) });
			expect(container.querySelector('form[action="?/saveRule"]')).not.toBeNull();
			expect(screen.getByRole('button', { name: /save rule/i })).toBeInTheDocument();
		});
	});

	describe('form contracts', () => {
		it('has saveRule form wired to ?/saveRule action', () => {
			const { container } = render(RulesTab, { props: defaultProps() });

			const form = container.querySelector('form[action="?/saveRule"]');
			expect(form).not.toBeNull();
			expect(screen.getByRole('button', { name: /save rule/i })).toBeInTheDocument();
		});

		it('saveRule form has objectID input and rule textarea', () => {
			render(RulesTab, { props: defaultProps() });

			const objectIdInput = screen.getByLabelText(/object id/i);
			expect(objectIdInput).toBeInTheDocument();
			expect(objectIdInput.getAttribute('name')).toBe('objectID');

			const ruleTextarea = screen.getByLabelText(/rule json/i);
			expect(ruleTextarea).toBeInTheDocument();
			expect(ruleTextarea.getAttribute('name')).toBe('rule');
		});

		it('rule textarea is seeded with default JSON template', () => {
			render(RulesTab, { props: defaultProps() });

			const textarea = screen.getByLabelText(/rule json/i) as HTMLTextAreaElement;
			const parsed = JSON.parse(textarea.value);
			expect(parsed).toHaveProperty('objectID', '');
			expect(parsed).toHaveProperty('conditions');
			expect(parsed).toHaveProperty('consequence');
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
	});
});
