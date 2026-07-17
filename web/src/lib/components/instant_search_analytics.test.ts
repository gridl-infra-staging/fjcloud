import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';

vi.mock('$app/environment', () => ({ browser: true }));

const { analyticsSpy } = vi.hoisted(() => ({
	analyticsSpy: vi.fn().mockResolvedValue(undefined)
}));

vi.mock('$lib/components/search/analytics_client', () => ({
	postSearchPreviewEvent: analyticsSpy,
	getSearchPreviewSessionToken: () => 'preview-11111111-1111-4111-8111-111111111111'
}));

import InstantSearch from './InstantSearch.svelte';

function createSearchResponse(overrides: Record<string, unknown> = {}) {
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
					facets: { brand: { Acme: 1 } },
					hits: [{ objectID: 'doc-1', title: 'Rust Guide' }],
					...overrides
				}
			]
		})
	};
}

afterEach(() => {
	cleanup();
	analyticsSpy.mockReset().mockResolvedValue(undefined);
	window.history.replaceState({}, '', '/');
	vi.unstubAllGlobals();
});

async function enableAnalyticsAndSearch(query = 'rust'): Promise<void> {
	await fireEvent.click(screen.getByLabelText('Record preview activity in Analytics'));
	const queryInput = screen.getByLabelText('Search preview query');
	await fireEvent.input(queryInput, { target: { value: query } });
	await fireEvent.keyDown(queryInput, { key: 'Enter' });
}

describe('InstantSearch analytics', () => {
	it('preserves the query ID and absolute position for explicit result opens', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue(createSearchResponse({ queryID: 'q-123', page: 1, totalPages: 2 }))
		);
		render(InstantSearch, { indexName: 'cust_products' });

		await enableAnalyticsAndSearch();
		await screen.findByText('Rust Guide');
		const searchBody = JSON.parse(
			(globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0][1].body
		);
		expect(searchBody.requests[0].params).toMatchObject({ analytics: true, clickAnalytics: true });
		await fireEvent.click(screen.getByRole('button', { name: 'Open details' }));

		expect(analyticsSpy).toHaveBeenCalledWith('cust_products', {
			eventName: 'search_preview_result_opened',
			objectID: 'doc-1',
			position: 21,
			queryID: 'q-123',
			userToken: 'preview-11111111-1111-4111-8111-111111111111'
		});
	});

	it('does not record result activity without an object ID', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue(
				createSearchResponse({
					queryID: 'q-missing-object',
					hits: [{ title: 'Unidentified result' }]
				})
			)
		);
		render(InstantSearch, { indexName: 'cust_products' });

		await enableAnalyticsAndSearch();
		await screen.findByText('Unidentified result');
		await fireEvent.click(screen.getByRole('button', { name: 'Open details' }));

		expect(analyticsSpy).not.toHaveBeenCalled();
		expect(screen.getByRole('status')).toHaveTextContent(
			'Not recorded: the result does not include an object ID.'
		);
	});

	it('requires a new search after preview activity is enabled', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue(createSearchResponse({ queryID: 'analytics-off-query-id' }))
		);
		render(InstantSearch, { indexName: 'cust_products' });

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'rust' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		await screen.findByText('Rust Guide');
		await fireEvent.click(screen.getByLabelText('Record preview activity in Analytics'));
		await fireEvent.click(screen.getByRole('button', { name: 'Open details' }));

		expect(analyticsSpy).not.toHaveBeenCalled();
		expect(screen.getByRole('status')).toHaveTextContent(
			'Not recorded: run a new search after enabling preview activity.'
		);
	});

	it('does not correlate retained hits while a replacement search is pending', async () => {
		let resolveReplacement!: (value: unknown) => void;
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(createSearchResponse({ queryID: 'old-query-id' }))
			.mockImplementationOnce(
				() =>
					new Promise((resolve) => {
						resolveReplacement = resolve;
					})
			);
		vi.stubGlobal('fetch', fetchMock);
		render(InstantSearch, { indexName: 'cust_products' });

		await enableAnalyticsAndSearch('old query');
		await screen.findByText('Rust Guide');
		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'replacement query' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		await screen.findByText('Updating results…');
		await fireEvent.click(screen.getByRole('button', { name: 'Open details' }));

		expect(analyticsSpy).not.toHaveBeenCalled();
		expect(screen.getByText('Not recorded: wait for the current search to finish.')).toBeVisible();
		resolveReplacement(createSearchResponse({ queryID: 'replacement-query-id' }));
		await waitFor(() => expect(screen.queryByText('Updating results…')).not.toBeInTheDocument());
	});

	it('warns instead of inventing a query ID for result activity', async () => {
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(createSearchResponse()));
		render(InstantSearch, { indexName: 'cust_products' });

		await enableAnalyticsAndSearch();
		await screen.findByText('Rust Guide');
		await fireEvent.click(screen.getByRole('button', { name: 'Open details' }));

		expect(analyticsSpy).not.toHaveBeenCalled();
		expect(screen.getByRole('status')).toHaveTextContent(
			'Not recorded: the search response did not include a query ID.'
		);
	});

	it('keeps event delivery failures visible without hiding search results', async () => {
		analyticsSpy.mockRejectedValueOnce(new Error('Search preview analytics failed: 429'));
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(createSearchResponse({ queryID: 'q-429' })));
		render(InstantSearch, { indexName: 'cust_products' });

		await enableAnalyticsAndSearch();
		await screen.findByText('Rust Guide');
		await fireEvent.click(screen.getByRole('button', { name: 'Open details' }));

		await waitFor(() =>
			expect(screen.getByRole('status')).toHaveTextContent(
				'Result open was not recorded: Search preview analytics failed: 429'
			)
		);
		expect(screen.getByText('Rust Guide')).toBeInTheDocument();
	});
});
