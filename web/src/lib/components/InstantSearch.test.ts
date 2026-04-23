import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

vi.mock('$app/environment', () => ({
	browser: true
}));

import InstantSearch from './InstantSearch.svelte';

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
	});
});
