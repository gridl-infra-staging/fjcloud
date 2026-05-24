import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

vi.mock('$app/environment', () => ({
	browser: true
}));

import InstantSearch from './InstantSearch.svelte';

const instantSearchSource = readFileSync(
	join(process.cwd(), 'src', 'lib', 'components', 'InstantSearch.svelte'),
	'utf8'
);

afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

describe('InstantSearch', () => {
	it('renders the search box contract', () => {
		render(InstantSearch, {
			endpoint: 'http://127.0.0.1:7700',
			apiKey: 'fj_search_123',
			indexName: 'cust_products'
		});

		expect(screen.getByTestId('instantsearch-widget')).toBeInTheDocument();
		expect(screen.getByPlaceholderText('Search your index...')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Submit the search query' })).toBeInTheDocument();
	});

	it('submits a query and renders visible hit content', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue({
				ok: true,
				json: async () => ({
					results: [
						{
							nbHits: 1,
							hits: [
								{
									objectID: 'doc-1',
									title: 'Rust Programming Language',
									body: 'Systems programming'
								}
							]
						}
					]
				})
			})
		);

		render(InstantSearch, {
			endpoint: 'http://127.0.0.1:7700',
			apiKey: 'fj_search_123',
			indexName: 'cust_products'
		});

		await fireEvent.input(screen.getByPlaceholderText('Search your index...'), {
			target: { value: 'Rust' }
		});
		await fireEvent.click(screen.getByRole('button', { name: 'Submit the search query' }));

		expect(await screen.findByText('Rust Programming Language')).toBeInTheDocument();
		expect(screen.getByText('Systems programming')).toBeInTheDocument();
	});

	it('shows the empty state when the search returns no hits', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue({
				ok: true,
				json: async () => ({
					results: [{ nbHits: 0, hits: [] }]
				})
			})
		);

		render(InstantSearch, {
			endpoint: 'http://127.0.0.1:7700',
			apiKey: 'fj_search_123',
			indexName: 'cust_products'
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Submit the search query' }));

		expect(await screen.findByText('No results found.')).toBeInTheDocument();
		expect(screen.getByText('No results found.')).toHaveClass('text-flapjack-ink/60');
	});

	it('keeps instantsearch css sourced from flapjack theme tokens', () => {
		expect(instantSearchSource).toContain('var(--color-flapjack-ink)');
		expect(instantSearchSource).toContain('var(--color-flapjack-rose)');
		expect(instantSearchSource).toContain('var(--color-flapjack-plum)');
		expect(instantSearchSource).not.toMatch(/#d1d5db|#2563eb|#e5e7eb|#6b7280/i);
	});
});
