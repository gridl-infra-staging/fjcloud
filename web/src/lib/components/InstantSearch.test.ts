import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/svelte';

vi.mock('$app/environment', () => ({
	browser: true
}));

const { analyticsSpy, instantSearchFormsMockState, toastSuccessMock } = vi.hoisted(() => ({
	analyticsSpy: vi.fn().mockResolvedValue(undefined),
	instantSearchFormsMockState: {
		enhanceSubmitFunctions: [] as Array<() => unknown>
	},
	toastSuccessMock: vi.fn()
}));

vi.mock('$lib/components/search/analytics_client', () => ({
	postSearchPreviewEvent: analyticsSpy,
	getSearchPreviewSessionToken: () => 'preview-11111111-1111-4111-8111-111111111111'
}));

vi.mock('$app/forms', () => ({
	enhance: (_element: HTMLFormElement, submitFunction?: () => unknown) => {
		if (submitFunction) {
			instantSearchFormsMockState.enhanceSubmitFunctions.push(submitFunction);
		}
		return { destroy: () => {} };
	}
}));

vi.mock('$lib/toast', async () => {
	const { TOAST_DURATION_MS } =
		await vi.importActual<typeof import('$lib/toast_contract')>('$lib/toast_contract');
	return {
		TOAST_DURATION_MS,
		toast: {
			success: toastSuccessMock
		}
	};
});

import InstantSearch from './InstantSearch.svelte';
import { TOAST_DURATION_MS } from '$lib/toast_contract';

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
					facets: {
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
	instantSearchFormsMockState.enhanceSubmitFunctions.length = 0;
	toastSuccessMock.mockClear();
	window.history.replaceState({}, '', '/');
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

async function resolveLatestDeleteEnhanceSuccess(): Promise<void> {
	const submitFunction = instantSearchFormsMockState.enhanceSubmitFunctions.at(-1);
	expect(submitFunction).toBeDefined();
	const resultHandler = submitFunction!() as ({
		result,
		update
	}: {
		result: unknown;
		update: () => Promise<void>;
	}) => Promise<void>;
	await resultHandler({
		result: { type: 'success', data: { documentsDeleteSuccess: true } },
		update: async () => {}
	});
}

describe('InstantSearch', () => {
	it('analytics off sends false and records no preview search', async () => {
		mockLocalStorage();
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue({
				...createSearchResponse()
			})
		);

		render(InstantSearch, {
			indexName: 'cust_products',
			configuredFacets: ['brand']
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, {
			target: { value: 'Rust' }
		});
		expect(globalThis.fetch).not.toHaveBeenCalled();
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(1));

		expect(await screen.findByText('Rust Guide')).toBeInTheDocument();
		const fetchBody = JSON.parse(
			(globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0][1].body
		);
		expect(fetchBody.requests[0].params).toEqual({
			query: 'Rust',
			page: 0,
			hitsPerPage: 20,
			facets: ['*'],
			analytics: false
		});
		expect(analyticsSpy).not.toHaveBeenCalled();
	});

	it('wires result delete forms to committed search state and emits one success toast on enhanced success', async () => {
		mockLocalStorage();
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(createSearchResponse()));

		const { container } = render(InstantSearch, {
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, {
			target: { value: 'Rust' }
		});
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		await screen.findByText('Rust Guide');

		const deleteForm = container.querySelector(
			'form[action="?/deleteDocument"]'
		) as HTMLFormElement | null;
		expect(deleteForm).not.toBeNull();
		expect(deleteForm?.getAttribute('method')).toBe('POST');
		expect(deleteForm?.querySelector<HTMLInputElement>('input[name="objectID"]')?.value).toBe(
			'doc-1'
		);
		expect(deleteForm?.querySelector<HTMLInputElement>('input[name="query"]')?.value).toBe('Rust');
		expect(deleteForm?.querySelector<HTMLInputElement>('input[name="hitsPerPage"]')?.value).toBe(
			'20'
		);

		await resolveLatestDeleteEnhanceSuccess();

		expect(toastSuccessMock).toHaveBeenCalledWith('Document deleted.', {
			duration: TOAST_DURATION_MS
		});
		expect(toastSuccessMock).toHaveBeenCalledTimes(1);
	});

	it('uses the raw route index through the authenticated search proxy', async () => {
		vi.stubGlobal('location', {
			href: 'https://cloud.staging.flapjack.foo/console/indexes/cold_customer_index?tab=search',
			protocol: 'https:'
		});
		vi.spyOn(window.history, 'replaceState').mockImplementation(() => {});
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue(
				createSearchResponse({
					hits: [
						{
							objectID: 'algolia_refugee_001',
							title: 'Blue Ridge trail running vest',
							description: 'Uploaded by the cold-customer browser journey'
						}
					],
					nbHits: 1
				})
			)
		);

		render(InstantSearch, {
			indexName: 'cold_customer_index'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, {
			target: { value: 'Blue Ridge' }
		});
		await fireEvent.keyDown(queryInput, { key: 'Enter' });

		expect(await screen.findByText('Blue Ridge trail running vest')).toBeInTheDocument();
		expect(screen.getByTestId('document-card')).toHaveTextContent('Blue Ridge trail running vest');
		expect(globalThis.fetch).toHaveBeenCalledWith('/api/search/cold_customer_index', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: expect.any(String)
		});
		expect(
			JSON.parse((globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0][1].body)
		).toEqual({
			requests: [
				{
					indexName: 'cold_customer_index',
					params: {
						query: 'Blue Ridge',
						page: 0,
						hitsPerPage: 20,
						facets: ['*'],
						analytics: false
					}
				}
			]
		});
	});

	it('keys search-as-you-type preference by the raw dashboard index name', async () => {
		mockLocalStorage({
			search_preview_instant_search: JSON.stringify({ cold_customer_index: true })
		});
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(createSearchResponse()));

		render(InstantSearch, {
			indexName: 'cold_customer_index'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'Blue' } });
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(1));

		const fetchBody = JSON.parse(
			(globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0][1].body
		);
		expect(fetchBody.requests[0].params.hitsPerPage).toBe(20);
		expect(fetchBody.requests[0].params.attributesToHighlight).toBeUndefined();
		expect(await screen.findByTestId('document-card-title')).toHaveTextContent('Rust Guide');
		expect(screen.getByLabelText('Search as you type')).toBeChecked();
	});

	it('uses a conventional image field in the compact preview card', async () => {
		const imageUrl = 'https://cdn.example.test/products/doc-1.png';
		mockLocalStorage();
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue(
				createSearchResponse({
					hits: [
						{
							objectID: 'doc-1',
							title: 'Water Bottle',
							image: imageUrl
						}
					],
					nbHits: 1
				})
			)
		);

		render(InstantSearch, {
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'bottle' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });

		const cardImage = await screen.findByTestId('document-card-image');
		expect(cardImage).toHaveAttribute('src', imageUrl);

		const fetchBody = JSON.parse(
			(globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0][1].body
		);
		expect(fetchBody.requests[0].params).toEqual({
			query: 'bottle',
			page: 0,
			hitsPerPage: 20,
			facets: ['*'],
			analytics: false
		});
	});

	it('does not submit a duplicate Enter search after instant input search', async () => {
		mockLocalStorage({
			search_preview_instant_search: JSON.stringify({ cust_products: true })
		});
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(createSearchResponse()));

		render(InstantSearch, {
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'Rust' } });
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(1));
		await fireEvent.keyDown(queryInput, { key: 'Enter' });

		expect(globalThis.fetch).toHaveBeenCalledTimes(1);
	});

	it('maps zero-based response page to one-based numbered UI before pagination requests', async () => {
		vi.stubGlobal(
			'fetch',
			vi
				.fn()
				.mockResolvedValueOnce(createSearchResponse({ page: 2, totalPages: 5 }))
				.mockResolvedValueOnce(createSearchResponse({ page: 3, totalPages: 5 }))
		);

		render(InstantSearch, {
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, {
			target: { value: 'Rust' }
		});
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		await screen.findByText('Rust Guide');

		expect(screen.getByRole('button', { name: 'Page 3' })).toHaveAttribute('aria-current', 'page');
		await fireEvent.click(screen.getByRole('button', { name: 'Page 4' }));
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(2));

		const secondBody = JSON.parse(
			(globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[1][1].body
		);
		const secondRequestParams = new URLSearchParams(secondBody.requests[0].params);
		expect(secondRequestParams.get('page')).toBe('3');
	});

	it('uses nbPages metadata for pagination when the search response omits totalPages', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue(
				createSearchResponse({
					nbHits: 45,
					nbPages: 3,
					totalPages: undefined
				})
			)
		);

		render(InstantSearch, {
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, {
			target: { value: 'Rust' }
		});
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		await screen.findByText('Rust Guide');

		expect(screen.getByRole('button', { name: 'Page 1' })).toHaveAttribute('aria-current', 'page');
		expect(screen.getByRole('button', { name: 'Page 2' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Next page' })).not.toBeDisabled();
	});

	it('falls back to one page when explicit page metadata is missing or invalid', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue(
				createSearchResponse({
					nbHits: 45,
					nbPages: 0,
					totalPages: undefined,
					hits: Array.from({ length: 20 }, (_, index) => ({
						objectID: `doc-${index + 1}`,
						title: `Rust Guide ${index + 1}`
					}))
				})
			)
		);

		render(InstantSearch, {
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, {
			target: { value: 'Rust' }
		});
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		await screen.findByText('Rust Guide 1');

		expect(screen.getByText('45 hits in 5ms')).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Page 2' })).not.toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Next page' })).toBeDisabled();
	});

	it('does not increase explicit nbPages from hit count or either page size', async () => {
		const hits = Array.from({ length: 20 }, (_, index) => ({ objectID: `doc-${index + 1}` }));
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue(
				createSearchResponse({
					nbHits: 45,
					nbPages: 1,
					totalPages: undefined,
					hitsPerPage: 50,
					hits
				})
			)
		);

		render(InstantSearch, {
			indexName: 'cust_products'
		});
		await fireEvent.input(screen.getByLabelText('Search preview query'), {
			target: { value: 'Rust' }
		});
		await fireEvent.keyDown(screen.getByLabelText('Search preview query'), { key: 'Enter' });
		await screen.findByText('45 hits in 5ms');

		expect(screen.queryByRole('button', { name: 'Page 2' })).not.toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Next page' })).toBeDisabled();
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
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, {
			target: { value: 'old query' }
		});
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		await fireEvent.input(queryInput, {
			target: { value: 'new query' }
		});
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
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

	it('renders an authenticated search error with a working Retry action', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce({ ok: false, status: 401 })
			.mockResolvedValueOnce(createSearchResponse());
		vi.stubGlobal('fetch', fetchMock);

		render(InstantSearch, {
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, {
			target: { value: 'session search query' }
		});
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		expect(await screen.findByRole('alert')).toHaveTextContent('Flapjack search failed: 401');

		await fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
		expect(await screen.findByText('Rust Guide')).toBeInTheDocument();
		expect(fetchMock).toHaveBeenCalledTimes(2);
	});

	it('keeps draft typing local until Enter commits search and URL state', async () => {
		mockLocalStorage();
		window.history.replaceState(
			{},
			'',
			'/console/indexes/products?source=create&tab=search&q=boots&p=3&f=brand%3AAcme&f=in_stock%3Atrue&hr=40'
		);
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(createSearchResponse()));

		render(InstantSearch, {
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query') as HTMLInputElement;
		expect(queryInput.value).toBe('boots');
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(1));

		await fireEvent.input(queryInput, { target: { value: 'rust' } });
		expect(queryInput.value).toBe('rust');
		expect(globalThis.fetch).toHaveBeenCalledTimes(1);
		expect(new URL(window.location.href).searchParams.get('q')).toBe('boots');

		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(2));

		const nextUrl = new URL(window.location.href);
		expect(nextUrl.searchParams.get('source')).toBe('create');
		expect(nextUrl.searchParams.get('tab')).toBe('search');
		expect(nextUrl.searchParams.get('p')).toBe('1');
		expect(nextUrl.searchParams.getAll('f')).toEqual(['brand:Acme', 'in_stock:true']);
		expect(nextUrl.searchParams.get('hr')).toBe('40');
	});

	it('keeps filter edits on the committed query and resets pagination to page 1', async () => {
		mockLocalStorage();
		window.history.replaceState({}, '', '/console/indexes/products?tab=search&q=boots&p=3&hr=20');
		vi.stubGlobal(
			'fetch',
			vi
				.fn()
				.mockResolvedValueOnce(createSearchResponse({ page: 2, totalPages: 5 }))
				.mockResolvedValueOnce(createSearchResponse({ page: 0, totalPages: 5 }))
		);

		render(InstantSearch, {
			indexName: 'cust_products'
		});

		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(1));
		await fireEvent.click(screen.getByRole('button', { name: 'Add advanced filter' }));
		await fireEvent.input(screen.getByLabelText('Advanced filter expression'), {
			target: { value: 'brand = "Acme"' }
		});
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(2));

		const secondBody = JSON.parse(
			(globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[1][1].body
		);
		const secondRequestParams = new URLSearchParams(secondBody.requests[0].params);
		expect(secondRequestParams.get('query')).toBe('boots');
		expect(secondRequestParams.get('filters')).toBe('brand = "Acme"');
		expect(secondRequestParams.get('page')).toBe('0');
		expect(new URL(window.location.href).searchParams.get('p')).toBe('1');
	});

	it('resyncs unsubmitted draft text to the committed query for non-query searches', async () => {
		mockLocalStorage();
		window.history.replaceState({}, '', '/console/indexes/products?tab=search&q=boots&p=2&hr=20');
		vi.stubGlobal(
			'fetch',
			vi
				.fn()
				.mockResolvedValueOnce(createSearchResponse({ page: 1, totalPages: 3 }))
				.mockResolvedValueOnce(createSearchResponse({ page: 0, totalPages: 3 }))
				.mockResolvedValueOnce(createSearchResponse({ page: 0, totalPages: 3 }))
				.mockResolvedValueOnce(createSearchResponse({ page: 1, totalPages: 3 }))
		);

		render(InstantSearch, {
			indexName: 'cust_products',
			configuredFacets: ['brand']
		});

		const queryInput = screen.getByLabelText('Search preview query') as HTMLInputElement;
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(1));

		await fireEvent.input(queryInput, { target: { value: 'draft filter query' } });
		await fireEvent.click(screen.getByRole('button', { name: 'Add advanced filter' }));
		await fireEvent.input(screen.getByLabelText('Advanced filter expression'), {
			target: { value: 'brand = "Acme"' }
		});
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(2));
		expect(queryInput.value).toBe('boots');

		await fireEvent.input(queryInput, { target: { value: 'draft facet query' } });
		await fireEvent.click(screen.getByLabelText('brand:Acme'));
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(3));
		expect(queryInput.value).toBe('boots');

		await fireEvent.input(queryInput, { target: { value: 'draft page query' } });
		await fireEvent.click(screen.getByRole('button', { name: 'Page 2' }));
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(4));
		expect(queryInput.value).toBe('boots');

		for (const [, init] of (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls) {
			const body = JSON.parse(init.body);
			const params = new URLSearchParams(body.requests[0].params);
			expect(params.get('query')).toBe('boots');
		}
		expect(new URL(window.location.href).searchParams.get('q')).toBe('boots');
	});

	it('searches on every keystroke when stored prefs enable instant search', async () => {
		mockLocalStorage({
			search_preview_instant_search: JSON.stringify({ cust_products: true })
		});
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(createSearchResponse()));

		render(InstantSearch, {
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'R' } });
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(1));
		await fireEvent.input(queryInput, { target: { value: 'Ru' } });
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(2));
	});

	it('keeps Stage 2 submit-on-Enter contract when instant search is disabled', async () => {
		mockLocalStorage({
			search_preview_instant_search: JSON.stringify({ cust_products: false })
		});
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(createSearchResponse()));

		render(InstantSearch, {
			indexName: 'cust_products'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'R' } });
		await fireEvent.input(queryInput, { target: { value: 'Ru' } });
		await fireEvent.input(queryInput, { target: { value: 'Rust' } });
		expect(globalThis.fetch).not.toHaveBeenCalled();

		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(1));
	});

	it('keeps keyboard focus inside the mobile Refine drawer', async () => {
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(createSearchResponse()));
		render(InstantSearch, { indexName: 'cust_products' });

		await fireEvent.click(screen.getByRole('button', { name: 'Refine (0)' }));
		const dialog = screen.getByRole('dialog', { name: 'Refine results' });
		const closeButton = within(dialog).getByRole('button', { name: 'Close' });
		const facetSettingsLink = within(dialog).getByRole('link', { name: 'Open facet settings' });
		await waitFor(() => expect(closeButton).toHaveFocus());

		await fireEvent.keyDown(closeButton, { key: 'Tab', shiftKey: true });

		expect(facetSettingsLink).toHaveFocus();
	});
});
