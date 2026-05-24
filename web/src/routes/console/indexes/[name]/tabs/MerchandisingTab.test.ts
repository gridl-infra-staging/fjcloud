import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { tick } from 'svelte';
import type { ComponentProps } from 'svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

import MerchandisingTab from './MerchandisingTab.svelte';
import { sampleIndex } from '../detail.test.shared';
import type { SearchResult } from '$lib/api/types';

type MerchandisingProps = ComponentProps<typeof MerchandisingTab>;

const sampleSearchResult: SearchResult = {
	hits: [
		{ objectID: 'prod-1', name: 'Apple iPhone 15' },
		{ objectID: 'prod-2', name: 'Samsung Galaxy S24' }
	],
	nbHits: 2,
	processingTimeMs: 2
};

function defaultProps(overrides: Partial<MerchandisingProps> = {}): MerchandisingProps {
	return {
		index: sampleIndex,
		searchResult: null,
		searchQuery: '',
		...overrides
	};
}

/**
 * Renders MerchandisingTab with search results and submits the query
 * so that merchandisingSourceHits() returns results.
 */
async function renderWithResults(
	query: string,
	result: SearchResult,
	overrides: Partial<MerchandisingProps> = {}
) {
	const rendered = render(MerchandisingTab, {
		props: defaultProps({ searchResult: result, searchQuery: query, ...overrides })
	});

	// Set the input value and submit the form to sync internal merchandisingSubmittedQuery
	const input = screen.getByPlaceholderText(/enter a search query/i) as HTMLInputElement;
	input.value = query;
	fireEvent.input(input);
	await tick();

	const form = rendered.container.querySelector('form[action="?/search"]') as HTMLFormElement;
	fireEvent.submit(form);
	await tick();

	return rendered;
}

afterEach(cleanup);

describe('MerchandisingTab', () => {
	describe('section shell', () => {
		it('renders the Merchandising heading', () => {
			render(MerchandisingTab, { props: defaultProps() });

			expect(screen.getByText('Merchandising')).toBeInTheDocument();
		});

		it('sets data-testid and data-index on the section root', () => {
			const { container } = render(MerchandisingTab, { props: defaultProps() });

			const section = container.querySelector('[data-testid="merchandising-section"]');
			expect(section).not.toBeNull();
			expect(section!.getAttribute('data-index')).toBe('products');
		});
	});

	describe('search form', () => {
		it('has search form wired to ?/search action', () => {
			const { container } = render(MerchandisingTab, { props: defaultProps() });

			const form = container.querySelector('form[action="?/search"]');
			expect(form).not.toBeNull();
		});

		it('has query input and Search button', () => {
			render(MerchandisingTab, { props: defaultProps() });

			expect(screen.getByPlaceholderText(/enter a search query/i)).toBeInTheDocument();
			expect(
				screen.getByRole('button', { name: 'Search Merchandising Results' })
			).toBeInTheDocument();
		});
	});

	describe('pre-search prompt', () => {
		it('shows prompt before any query is submitted', () => {
			render(MerchandisingTab, { props: defaultProps() });

			expect(screen.getByText('Enter a search query')).toBeInTheDocument();
			expect(screen.getByText(/search and then pin or hide results/i)).toBeInTheDocument();
		});
	});

	describe('search results', () => {
		it('displays results after submitting a matching query', async () => {
			await renderWithResults('phone', sampleSearchResult);

			expect(screen.getByText('Apple iPhone 15')).toBeInTheDocument();
			expect(screen.getByText('Samsung Galaxy S24')).toBeInTheDocument();
		});

		it('shows Pin and Hide buttons for each result', async () => {
			await renderWithResults('phone', sampleSearchResult);

			expect(screen.getByRole('button', { name: 'Pin prod-1' })).toBeInTheDocument();
			expect(screen.getByRole('button', { name: 'Hide prod-1' })).toBeInTheDocument();
			expect(screen.getByRole('button', { name: 'Pin prod-2' })).toBeInTheDocument();
			expect(screen.getByRole('button', { name: 'Hide prod-2' })).toBeInTheDocument();
		});

		it('shows "No results" when searchResult has no hits after query', async () => {
			const emptyResult: SearchResult = { hits: [], nbHits: 0, processingTimeMs: 1 };
			await renderWithResults('nomatches', emptyResult);

			expect(screen.getByText('No results')).toBeInTheDocument();
		});

		it('does not show pre-search prompt after query submission', async () => {
			await renderWithResults('phone', sampleSearchResult);

			expect(screen.queryByText(/search and then pin or hide results/i)).not.toBeInTheDocument();
		});
	});

	describe('pin and hide actions', () => {
		it('pinning a result shows summary bar with counts', async () => {
			await renderWithResults('phone', sampleSearchResult);

			await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));

			expect(screen.getByText(/1 pinned, 0 hidden/)).toBeInTheDocument();
		});

		it('hiding a result shows summary bar and hidden results section', async () => {
			await renderWithResults('phone', sampleSearchResult);

			await fireEvent.click(screen.getByRole('button', { name: 'Hide prod-2' }));

			expect(screen.getByText(/0 pinned, 1 hidden/)).toBeInTheDocument();
			expect(screen.getByText('Hidden results')).toBeInTheDocument();
			expect(screen.getByText('Samsung Galaxy S24')).toBeInTheDocument();
		});

		it('hiding a pinned item removes the pin and adds the hide', async () => {
			await renderWithResults('phone', sampleSearchResult);

			// Pin first, then hide the same item — toggleHide removes from pins
			await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));
			expect(screen.getByText(/1 pinned, 0 hidden/)).toBeInTheDocument();

			await fireEvent.click(screen.getByRole('button', { name: 'Hide prod-1' }));
			expect(screen.getByText(/0 pinned, 1 hidden/)).toBeInTheDocument();
		});

		it('toggling pin off removes it from pin count', async () => {
			await renderWithResults('phone', sampleSearchResult);

			await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));
			expect(screen.getByText(/1 pinned, 0 hidden/)).toBeInTheDocument();

			// Click pin again to unpin
			await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));
			// Summary bar should be gone (0 pinned, 0 hidden)
			expect(screen.queryByText(/pinned/)).not.toBeInTheDocument();
		});
	});

	describe('summary bar actions', () => {
		it('shows Reset and Save as Rule buttons when items are pinned', async () => {
			await renderWithResults('phone', sampleSearchResult);

			await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));

			expect(screen.getByRole('button', { name: 'Reset Merchandising' })).toBeInTheDocument();
			expect(screen.getByRole('button', { name: 'Save as Rule' })).toBeInTheDocument();
		});

		it('Reset clears pins, hides, and summary bar', async () => {
			await renderWithResults('phone', sampleSearchResult);

			await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));
			await fireEvent.click(screen.getByRole('button', { name: 'Hide prod-2' }));
			expect(screen.getByText(/1 pinned, 1 hidden/)).toBeInTheDocument();

			await fireEvent.click(screen.getByRole('button', { name: 'Reset Merchandising' }));

			expect(screen.queryByText(/pinned/)).not.toBeInTheDocument();
			expect(screen.queryByText('Hidden results')).not.toBeInTheDocument();
		});
	});

	describe('save as rule flow', () => {
		it('Save as Rule button builds rule and shows saveRule form', async () => {
			const { container } = await renderWithResults('phone', sampleSearchResult);

			await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));
			await fireEvent.click(screen.getByRole('button', { name: 'Save as Rule' }));

			const form = container.querySelector('form[action="?/saveRule"]');
			expect(form).not.toBeNull();
			expect(screen.getByRole('button', { name: 'Confirm Save Rule' })).toBeInTheDocument();
		});

		it('saveRule form has hidden objectID and rule inputs', async () => {
			const { container } = await renderWithResults('phone', sampleSearchResult);

			await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));
			await fireEvent.click(screen.getByRole('button', { name: 'Save as Rule' }));

			const form = container.querySelector('form[action="?/saveRule"]')!;
			const objectIDInput = form.querySelector('input[name="objectID"]') as HTMLInputElement;
			const ruleInput = form.querySelector('input[name="rule"]') as HTMLInputElement;

			expect(objectIDInput).not.toBeNull();
			expect(objectIDInput.value).toMatch(/^merch-/);
			expect(ruleInput).not.toBeNull();

			const parsed = JSON.parse(ruleInput.value);
			expect(parsed.consequence.promote).toBeDefined();
			expect(parsed.consequence.promote[0].objectID).toBe('prod-1');
		});

		it('rule payload includes hide consequence when items are hidden', async () => {
			const { container } = await renderWithResults('phone', sampleSearchResult);

			await fireEvent.click(screen.getByRole('button', { name: 'Hide prod-2' }));
			await fireEvent.click(screen.getByRole('button', { name: 'Save as Rule' }));

			const form = container.querySelector('form[action="?/saveRule"]')!;
			const ruleInput = form.querySelector('input[name="rule"]') as HTMLInputElement;
			const parsed = JSON.parse(ruleInput.value);
			expect(parsed.consequence.hide).toBeDefined();
			expect(parsed.consequence.hide[0].objectID).toBe('prod-2');
		});

		it('rule condition anchoring is "is" for the submitted query', async () => {
			const { container } = await renderWithResults('phone', sampleSearchResult);

			await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));
			await fireEvent.click(screen.getByRole('button', { name: 'Save as Rule' }));

			const form = container.querySelector('form[action="?/saveRule"]')!;
			const ruleInput = form.querySelector('input[name="rule"]') as HTMLInputElement;
			const parsed = JSON.parse(ruleInput.value);
			expect(parsed.conditions).toEqual([{ pattern: 'phone', anchoring: 'is' }]);
		});

		it('saveRule form is not visible before Save as Rule is clicked', async () => {
			const { container } = await renderWithResults('phone', sampleSearchResult);

			await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));

			// Form should not exist yet
			expect(container.querySelector('form[action="?/saveRule"]')).toBeNull();
		});
	});

	describe('query mismatch handling', () => {
		it('shows no results when searchQuery does not match submitted query', async () => {
			render(MerchandisingTab, {
				props: defaultProps({
					searchResult: sampleSearchResult,
					searchQuery: 'different-query'
				})
			});

			// Submit with 'phone' but searchQuery prop is 'different-query'
			const input = screen.getByPlaceholderText(/enter a search query/i) as HTMLInputElement;
			input.value = 'phone';
			fireEvent.input(input);
			await tick();

			const form = screen
				.getByRole('button', { name: 'Search Merchandising Results' })
				.closest('form') as HTMLFormElement;
			fireEvent.submit(form);
			await tick();

			expect(screen.getByText('No results')).toBeInTheDocument();
		});
	});
});
