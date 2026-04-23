import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { tick } from 'svelte';
import type { ComponentProps } from 'svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

import SynonymsTab from './SynonymsTab.svelte';
import { sampleIndex, sampleSynonyms } from '../detail.test.shared';
import type { SynonymSearchResponse } from '$lib/api/types';

type SynonymsProps = ComponentProps<typeof SynonymsTab>;

function defaultProps(overrides: Partial<SynonymsProps> = {}): SynonymsProps {
	return {
		index: sampleIndex,
		synonyms: sampleSynonyms,
		synonymError: '',
		synonymSaved: false,
		synonymDeleted: false,
		...overrides
	};
}

afterEach(cleanup);

describe('SynonymsTab', () => {
	describe('section shell', () => {
		it('renders the Synonyms heading and description', () => {
			render(SynonymsTab, { props: defaultProps() });

			expect(screen.getByText('Synonyms')).toBeInTheDocument();
			expect(screen.getByText(/create and manage synonym sets/i)).toBeInTheDocument();
		});

		it('sets data-testid and data-index on the section root', () => {
			const { container } = render(SynonymsTab, { props: defaultProps() });

			const section = container.querySelector('[data-testid="synonyms-section"]');
			expect(section).not.toBeNull();
			expect(section!.getAttribute('data-index')).toBe('products');
		});
	});

	describe('success and error banners', () => {
		it('shows saved banner when synonymSaved is true', () => {
			render(SynonymsTab, { props: defaultProps({ synonymSaved: true }) });
			expect(screen.getByText('Synonym saved.')).toBeInTheDocument();
		});

		it('shows deleted banner when synonymDeleted is true', () => {
			render(SynonymsTab, { props: defaultProps({ synonymDeleted: true }) });
			expect(screen.getByText('Synonym deleted.')).toBeInTheDocument();
		});

		it('shows error banner with error message', () => {
			render(SynonymsTab, { props: defaultProps({ synonymError: 'Bad format' }) });
			expect(screen.getByText('Bad format')).toBeInTheDocument();
		});

		it('does not show banners by default', () => {
			render(SynonymsTab, { props: defaultProps() });
			expect(screen.queryByText('Synonym saved.')).not.toBeInTheDocument();
			expect(screen.queryByText('Synonym deleted.')).not.toBeInTheDocument();
		});
	});

	describe('empty vs populated synonym table', () => {
		it('shows empty state when synonym list is empty', () => {
			render(SynonymsTab, {
				props: defaultProps({ synonyms: { hits: [], nbHits: 0 } })
			});
			expect(screen.getByText('No synonyms')).toBeInTheDocument();
		});

		it('renders synonym row with objectID and type badge', () => {
			render(SynonymsTab, { props: defaultProps() });

			expect(screen.getByText('laptop-syn')).toBeInTheDocument();
			// Type badge shows "synonym"
			const badges = screen.getAllByText('synonym');
			expect(badges.length).toBeGreaterThanOrEqual(1);
		});

		it('renders synonym summary for multi-way synonym', () => {
			render(SynonymsTab, { props: defaultProps() });

			// sampleSynonyms has synonyms: ['laptop', 'notebook', 'computer']
			// synonymSummary joins them with ' = '
			expect(screen.getByText('laptop = notebook = computer')).toBeInTheDocument();
		});

		it('renders summary for onewaysynonym type', () => {
			const oneWaySynonyms: SynonymSearchResponse = {
				hits: [
					{
						objectID: 'phone-syn',
						type: 'onewaysynonym',
						input: 'mobile',
						synonyms: ['phone', 'cell']
					}
				],
				nbHits: 1
			};
			render(SynonymsTab, { props: defaultProps({ synonyms: oneWaySynonyms }) });

			expect(screen.getByText('mobile -> phone, cell')).toBeInTheDocument();
		});

		it('renders summary for altcorrection1 type', () => {
			const altSynonyms: SynonymSearchResponse = {
				hits: [
					{
						objectID: 'alt-syn',
						type: 'altcorrection1',
						word: 'colour',
						corrections: ['color']
					}
				],
				nbHits: 1
			};
			render(SynonymsTab, { props: defaultProps({ synonyms: altSynonyms }) });

			expect(screen.getByText('colour -> color')).toBeInTheDocument();
		});

		it('renders summary for placeholder type', () => {
			const placeholderSynonyms: SynonymSearchResponse = {
				hits: [
					{
						objectID: 'ph-syn',
						type: 'placeholder',
						placeholder: '<brand>',
						replacements: ['Nike', 'Adidas']
					}
				],
				nbHits: 1
			};
			render(SynonymsTab, { props: defaultProps({ synonyms: placeholderSynonyms }) });

			expect(screen.getByText('<brand> => Nike, Adidas')).toBeInTheDocument();
		});

		it('renders table headers for objectID, Type, and Summary', () => {
			const { container } = render(SynonymsTab, { props: defaultProps() });

			expect(screen.getByText('objectID')).toBeInTheDocument();
			// "Type" appears both as a th and a form label — scope to thead
			const thead = container.querySelector('thead');
			expect(thead).not.toBeNull();
			expect(thead!.textContent).toContain('Type');
			expect(screen.getByText('Summary')).toBeInTheDocument();
		});
	});

	describe('degraded state when synonyms fetch failed', () => {
		it('shows load-failure message when synonyms is null', () => {
			render(SynonymsTab, { props: defaultProps({ synonyms: null }) });
			expect(screen.getByText(/synonyms could not be loaded/i)).toBeInTheDocument();
		});

		it('does not show "No synonyms" empty state when synonyms is null', () => {
			render(SynonymsTab, { props: defaultProps({ synonyms: null }) });
			expect(screen.queryByText('No synonyms')).not.toBeInTheDocument();
		});

		it('keeps the add/update form available when synonyms is null', () => {
			const { container } = render(SynonymsTab, { props: defaultProps({ synonyms: null }) });
			expect(container.querySelector('form[action="?/saveSynonym"]')).not.toBeNull();
			expect(screen.getByRole('button', { name: /save synonym/i })).toBeInTheDocument();
		});
	});

	describe('form contracts', () => {
		it('has saveSynonym form wired to ?/saveSynonym action', () => {
			const { container } = render(SynonymsTab, { props: defaultProps() });

			const form = container.querySelector('form[action="?/saveSynonym"]');
			expect(form).not.toBeNull();
			expect(screen.getByRole('button', { name: /save synonym/i })).toBeInTheDocument();
		});

		it('saveSynonym form has objectID input, type select, and synonym textarea', () => {
			render(SynonymsTab, { props: defaultProps() });

			const objectIdInput = screen.getByLabelText(/object id/i);
			expect(objectIdInput).toBeInTheDocument();
			expect(objectIdInput.getAttribute('name')).toBe('objectID');

			const typeSelect = screen.getByLabelText(/^type$/i);
			expect(typeSelect).toBeInTheDocument();

			const synonymTextarea = screen.getByLabelText(/synonym json/i);
			expect(synonymTextarea).toBeInTheDocument();
			expect(synonymTextarea.getAttribute('name')).toBe('synonym');
		});

		it('type selector lists all five synonym types', () => {
			render(SynonymsTab, { props: defaultProps() });

			const typeSelect = screen.getByLabelText(/^type$/i) as HTMLSelectElement;
			const options = Array.from(typeSelect.querySelectorAll('option')).map((o) => o.value);
			expect(options).toEqual([
				'synonym',
				'onewaysynonym',
				'altcorrection1',
				'altcorrection2',
				'placeholder'
			]);
		});

		it('has deleteSynonym form per synonym row wired to ?/deleteSynonym action', () => {
			const { container } = render(SynonymsTab, { props: defaultProps() });

			const deleteForms = container.querySelectorAll('form[action="?/deleteSynonym"]');
			expect(deleteForms.length).toBe(1);

			const hiddenInput = deleteForms[0].querySelector('input[name="objectID"]') as HTMLInputElement;
			expect(hiddenInput.value).toBe('laptop-syn');
		});

		it('delete button has accessible label with synonym objectID', () => {
			render(SynonymsTab, { props: defaultProps() });

			expect(
				screen.getByRole('button', { name: /delete synonym laptop-syn/i })
			).toBeInTheDocument();
		});
	});

	describe('synonym template behavior', () => {
		it('seeds textarea with default synonym template on initial render', () => {
			render(SynonymsTab, { props: defaultProps() });

			const textarea = screen.getByLabelText(/synonym json/i) as HTMLTextAreaElement;
			const parsed = JSON.parse(textarea.value);
			expect(parsed).toHaveProperty('type', 'synonym');
			expect(parsed).toHaveProperty('synonyms');
			expect(parsed.objectID).toBe('');
		});

		it('refreshes template when type selector changes', async () => {
			render(SynonymsTab, { props: defaultProps() });

			const typeSelect = screen.getByLabelText(/^type$/i) as HTMLSelectElement;
			// Set the DOM value directly so Svelte's bind:value reads the new value
			typeSelect.value = 'onewaysynonym';
			fireEvent.change(typeSelect);
			await tick();

			const textarea = screen.getByLabelText(/synonym json/i) as HTMLTextAreaElement;
			const parsed = JSON.parse(textarea.value);
			expect(parsed).toHaveProperty('type', 'onewaysynonym');
			expect(parsed).toHaveProperty('input');
			expect(parsed).toHaveProperty('synonyms');
		});

		it('refreshes template when objectID input changes', async () => {
			render(SynonymsTab, { props: defaultProps() });

			const objectIdInput = screen.getByLabelText(/object id/i) as HTMLInputElement;
			// Set the DOM value directly so Svelte's bind:value reads the new value
			objectIdInput.value = 'my-syn';
			fireEvent.input(objectIdInput);
			await tick();

			const textarea = screen.getByLabelText(/synonym json/i) as HTMLTextAreaElement;
			const parsed = JSON.parse(textarea.value);
			expect(parsed.objectID).toBe('my-syn');
		});

		it('produces altcorrection1 template with word and corrections fields', async () => {
			render(SynonymsTab, { props: defaultProps() });

			const typeSelect = screen.getByLabelText(/^type$/i) as HTMLSelectElement;
			typeSelect.value = 'altcorrection1';
			fireEvent.change(typeSelect);
			await tick();

			const textarea = screen.getByLabelText(/synonym json/i) as HTMLTextAreaElement;
			const parsed = JSON.parse(textarea.value);
			expect(parsed).toHaveProperty('type', 'altcorrection1');
			expect(parsed).toHaveProperty('word', '');
			expect(parsed).toHaveProperty('corrections');
		});

		it('produces placeholder template with placeholder and replacements fields', async () => {
			render(SynonymsTab, { props: defaultProps() });

			const typeSelect = screen.getByLabelText(/^type$/i) as HTMLSelectElement;
			typeSelect.value = 'placeholder';
			fireEvent.change(typeSelect);
			await tick();

			const textarea = screen.getByLabelText(/synonym json/i) as HTMLTextAreaElement;
			const parsed = JSON.parse(textarea.value);
			expect(parsed).toHaveProperty('type', 'placeholder');
			expect(parsed).toHaveProperty('placeholder', '');
			expect(parsed).toHaveProperty('replacements');
		});
	});
});
