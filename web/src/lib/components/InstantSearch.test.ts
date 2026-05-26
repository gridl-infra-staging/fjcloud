import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';

vi.mock('$app/environment', () => ({
	browser: true
}));

const { analyticsSpy } = vi.hoisted(() => ({
	analyticsSpy: vi.fn().mockResolvedValue(undefined)
}));

vi.mock('$lib/components/search/analytics_client', () => ({
	postSearchPreviewEvent: analyticsSpy
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
					facetDistribution: {
						brand: { Acme: 1 }
					},
					hits: [
						{
							objectID: 'doc-1',
							title: 'Rust Guide',
							body: 'Fast systems programming'
						}
					],
					...overrides
				}
			]
		})
	};
}

function mockLocalStorage(initial: Record<string, string> = {}) {
	const store = new Map(Object.entries(initial));
	const getItem = vi.fn((key: string) => store.get(key) ?? null);
	const setItem = vi.fn((key: string, value: string) => {
		store.set(key, value);
	});
	const clear = vi.fn(() => {
		store.clear();
	});
	vi.stubGlobal('localStorage', { getItem, setItem, clear });
	return { getItem, setItem, clear };
}

afterEach(() => {
	cleanup();
	analyticsSpy.mockClear();
	window.history.replaceState({}, '', '/');
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

describe('InstantSearch', () => {
	it('preserves instantsearch testids while rendering composed Stage 4 primitives', () => {
		render(InstantSearch, {
			endpoint: 'http://127.0.0.1:7700',
			apiKey: 'fj_search_123',
			indexName: 'cust_products'
		});

		expect(screen.getByTestId('instantsearch-widget')).toBeInTheDocument();
		expect(screen.getByTestId('instantsearch-searchbox')).toBeInTheDocument();
		expect(screen.getByTestId('instantsearch-hits')).toBeInTheDocument();
		expect(screen.getByTestId('search-preview-header')).toBeInTheDocument();
		expect(screen.getByTestId('search-preview-box')).toBeInTheDocument();
		expect(screen.getByTestId('search-preview-facets')).toBeInTheDocument();
		expect(screen.getByTestId('search-preview-results')).toBeInTheDocument();
	});

	it('builds canonical preview params through the client request and renders hits', async () => {
		const localStorageMock = mockLocalStorage();
		localStorageMock.setItem(
			'search_preview_display_prefs',
			JSON.stringify({ hitsPerPage: 30, highlightedAttributes: ['title', 'body'] })
		);
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue({
				...createSearchResponse()
			})
		);

		render(InstantSearch, {
			endpoint: 'http://127.0.0.1:7700',
			apiKey: 'fj_search_123',
			indexName: 'cust_products'
		});

		await fireEvent.input(screen.getByLabelText('Search preview query'), {
			target: { value: 'Rust' }
		});
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(1));

		expect(await screen.findByText('Rust Guide')).toBeInTheDocument();
		const fetchBody = JSON.parse(
			(globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0][1].body
		);
		const requestParams = new URLSearchParams(fetchBody.requests[0].params);

		expect(requestParams.get('query')).toBe('Rust');
		expect(requestParams.get('page')).toBe('0');
		expect(requestParams.get('hitsPerPage')).toBe('30');
		expect(requestParams.get('attributesToHighlight')).toBe('["title","body"]');
		expect(requestParams.get('facets')).toBe('["*"]');
	});

	it('maps zero-based response page to one-based UI before pagination requests', async () => {
		vi.stubGlobal(
			'fetch',
			vi
				.fn()
				.mockResolvedValueOnce(createSearchResponse({ page: 2, totalPages: 5 }))
				.mockResolvedValueOnce(createSearchResponse({ page: 3, totalPages: 5 }))
		);

		render(InstantSearch, {
			endpoint: 'http://127.0.0.1:7700',
			apiKey: 'fj_search_123',
			indexName: 'cust_products'
		});

		await fireEvent.input(screen.getByLabelText('Search preview query'), {
			target: { value: 'Rust' }
		});
		await screen.findByText('Rust Guide');

		await fireEvent.click(screen.getByRole('button', { name: 'Next page' }));
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(2));

		const secondBody = JSON.parse(
			(globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[1][1].body
		);
		const secondRequestParams = new URLSearchParams(secondBody.requests[0].params);
		expect(secondRequestParams.get('page')).toBe('3');
	});

	it('drops stale responses via activeRequest when a newer search finishes later', async () => {
		const deferredResolvers: Array<(value: unknown) => void> = [];
		const fetchMock = vi.fn().mockImplementation(
			() =>
				new Promise((resolve) => {
					deferredResolvers.push(resolve);
				})
		);
		vi.stubGlobal('fetch', fetchMock);

		render(InstantSearch, {
			endpoint: 'http://127.0.0.1:7700',
			apiKey: 'fj_search_123',
			indexName: 'cust_products'
		});

		await fireEvent.input(screen.getByLabelText('Search preview query'), {
			target: { value: 'old query' }
		});
		await fireEvent.input(screen.getByLabelText('Search preview query'), {
			target: { value: 'new query' }
		});
		expect(fetchMock).toHaveBeenCalledTimes(2);

		deferredResolvers[1](
			createSearchResponse({
				hits: [{ objectID: 'doc-new', title: 'Newest Result' }],
				nbHits: 1
			})
		);
		await screen.findByText('Newest Result');

		deferredResolvers[0](
			createSearchResponse({
				hits: [{ objectID: 'doc-old', title: 'Stale Result' }],
				nbHits: 1
			})
		);
		await waitFor(() => expect(screen.queryByText('Stale Result')).not.toBeInTheDocument());
	});

	it('signals expired preview key through exactly one callback seam on 401/403', async () => {
		const onPreviewKeyExpired = vi.fn();
		const fetchMock = vi.fn().mockResolvedValue({
			ok: false,
			status: 401
		});
		vi.stubGlobal('fetch', fetchMock);

		render(InstantSearch, {
			endpoint: 'http://127.0.0.1:7700',
			apiKey: 'fj_search_123',
			indexName: 'cust_products',
			onPreviewKeyExpired
		});

		await fireEvent.input(screen.getByLabelText('Search preview query'), {
			target: { value: 'expired key query' }
		});
		await waitFor(() => expect(onPreviewKeyExpired).toHaveBeenCalledTimes(1));
	});

	it('signals expired preview key through same callback seam on 403', async () => {
		const onPreviewKeyExpired = vi.fn();
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue({
				ok: false,
				status: 403
			})
		);

		render(InstantSearch, {
			endpoint: 'http://127.0.0.1:7700',
			apiKey: 'fj_search_123',
			indexName: 'cust_products',
			onPreviewKeyExpired
		});

		await fireEvent.input(screen.getByLabelText('Search preview query'), {
			target: { value: 'expired key query' }
		});
		await waitFor(() => expect(onPreviewKeyExpired).toHaveBeenCalledTimes(1));
	});

	it('round-trips q/p/f/hr URL state and preserves foreign query keys', async () => {
		mockLocalStorage();
		window.history.replaceState(
			{},
			'',
			'/console/indexes/products?welcome=1&tab=search-preview&q=boots&p=3&f=brand%3AAcme%2Cin_stock%3Atrue&hr=40'
		);
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(createSearchResponse()));

		render(InstantSearch, {
			endpoint: 'http://127.0.0.1:7700',
			apiKey: 'fj_search_123',
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query') as HTMLInputElement;
		expect(queryInput.value).toBe('boots');

		await fireEvent.input(queryInput, { target: { value: 'rust' } });
		await waitFor(() => expect(new URL(window.location.href).searchParams.get('q')).toBe('rust'));

		const nextUrl = new URL(window.location.href);
		expect(nextUrl.searchParams.get('welcome')).toBe('1');
		expect(nextUrl.searchParams.get('tab')).toBe('search-preview');
		expect(nextUrl.searchParams.get('p')).toBe('1');
		expect(nextUrl.searchParams.get('f')).toBe('brand:Acme,in_stock:true');
		expect(nextUrl.searchParams.get('hr')).toBe('40');
	});

	it('tracks result click analytics only when toggle is enabled', async () => {
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(createSearchResponse()));

		render(InstantSearch, {
			endpoint: 'http://127.0.0.1:7700',
			apiKey: 'fj_search_123',
			indexName: 'cust_products'
		});

		await fireEvent.input(screen.getByLabelText('Search preview query'), {
			target: { value: 'rust' }
		});
		await screen.findByText('Rust Guide');
		await fireEvent.click(screen.getByText('Rust Guide'));

		expect(analyticsSpy).not.toHaveBeenCalled();

		await fireEvent.click(screen.getByLabelText('Track analytics events'));
		await fireEvent.click(screen.getByText('Rust Guide'));

		expect(analyticsSpy).toHaveBeenCalledWith('http://127.0.0.1:7700', 'fj_search_123', {
			type: 'search_preview_result_click',
			query: 'rust',
			indexName: 'cust_products',
			metadata: {
				objectID: 'doc-1',
				page: 1
			}
		});
	});
});
