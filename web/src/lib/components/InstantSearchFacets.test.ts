import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

vi.mock('$app/environment', () => ({ browser: true }));

import InstantSearch from './InstantSearch.svelte';

function searchResponse(overrides: Record<string, unknown>) {
	return {
		ok: true,
		status: 200,
		json: async () => ({
			results: [
				{
					nbHits: 1,
					processingTimeMS: 5,
					page: 0,
					totalPages: 1,
					hits: [{ objectID: 'movie-1', title: 'The Dark Knight' }],
					...overrides
				}
			]
		})
	};
}

afterEach(() => {
	cleanup();
	window.history.replaceState({}, '', '/');
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

describe('InstantSearch facet configuration', () => {
	it('renders standard facets response with exact configured Movies counts', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue(
				searchResponse({
					facets: {
						genre: { Action: 2, Drama: 3 },
						director: { 'Christopher Nolan': 2 },
						year: { '2008': 1, '2010': 1 }
					}
				})
			)
		);

		render(InstantSearch, {
			indexName: 'movies',
			configuredFacets: ['genre', 'director', 'year']
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'dark' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });

		const genrePanel = await screen.findByTestId('facet-panel-genre');
		expect(genrePanel).toHaveTextContent('Action');
		expect(genrePanel).toHaveTextContent('2');
		expect(genrePanel).toHaveTextContent('Drama');
		expect(genrePanel).toHaveTextContent('3');
		expect(screen.getByTestId('facet-panel-director')).toHaveTextContent('Christopher Nolan');
		expect(screen.getByTestId('facet-panel-year')).toHaveTextContent('2010');
	});

	it('uses loaded settings and document samples without an automatic search request', async () => {
		const fetchMock = vi.fn();
		vi.stubGlobal('fetch', fetchMock);
		vi.stubGlobal('localStorage', {
			getItem: vi.fn(() => null),
			setItem: vi.fn(),
			clear: vi.fn()
		});

		render(InstantSearch, {
			indexName: 'movies',
			configuredFacets: ['genre', 'director', 'year'],
			documentSample: [
				{
					objectID: 'movie-1',
					title: 'The Dark Knight',
					overview: 'Batman faces the Joker',
					poster_url: 'https://images.example.test/dark-knight.jpg',
					genre: ['Action', 'Drama']
				}
			]
		});

		expect(fetchMock).not.toHaveBeenCalled();
		expect(screen.getByTestId('facet-panel-genre')).toHaveTextContent(
			'No values for these results'
		);

		expect(screen.queryByRole('button', { name: 'Display preferences' })).not.toBeInTheDocument();
		expect(screen.getByLabelText('Search as you type')).not.toBeChecked();
		expect(fetchMock).not.toHaveBeenCalled();
	});
});
