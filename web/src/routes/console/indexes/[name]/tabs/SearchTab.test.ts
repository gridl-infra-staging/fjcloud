import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import type { Index } from '$lib/api/types';

const { invalidateAllMock } = vi.hoisted(() => ({ invalidateAllMock: vi.fn() }));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/environment', () => ({
	browser: true
}));

vi.mock('$app/navigation', () => ({
	invalidateAll: invalidateAllMock
}));

import SearchTab from './SearchTab.svelte';

const activeIndex: Index = {
	name: 'products',
	region: 'us-east-1',
	endpoint: 'https://vm-abc.flapjack.foo',
	entries: 100,
	data_size_bytes: 1024,
	status: 'ready',
	tier: 'active',
	created_at: '2026-01-01T00:00:00Z'
};

function stubBrowserSearch(hits: Array<Record<string, unknown>>, page = 0): void {
	vi.stubGlobal('location', {
		href: 'https://cloud.staging.flapjack.foo/console/indexes/products?tab=search',
		protocol: 'https:'
	});
	vi.spyOn(window.history, 'replaceState').mockImplementation(() => {});
	vi.stubGlobal(
		'fetch',
		vi.fn().mockResolvedValue({
			ok: true,
			status: 200,
			json: async () => ({
				results: [
					{
						nbHits: hits.length,
						processingTimeMS: 5,
						page,
						totalPages: 1,
						hits
					}
				]
			})
		})
	);
}

afterEach(() => {
	cleanup();
	window.history.replaceState({}, '', '/');
	vi.unstubAllGlobals();
	vi.clearAllMocks();
});

describe('SearchTab', () => {
	it('explains cold storage and offers the customer restore action', () => {
		const coldIndex: Index = { ...activeIndex, tier: 'cold' };
		render(SearchTab, {
			index: coldIndex,
			restoreError: 'Maximum concurrent restores reached. Try again later.'
		});

		expect(
			screen.getByText('This index is in cold storage to reduce storage costs.')
		).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Restore index' })).toBeInTheDocument();
		expect(screen.getByRole('alert')).toHaveTextContent(
			'Maximum concurrent restores reached. Try again later.'
		);
		expect(screen.queryByText(/please wait/i)).not.toBeInTheDocument();
	});

	it('explains restoring state and lets the customer refresh it', async () => {
		const restoringIndex: Index = { ...activeIndex, tier: 'restoring' };
		render(SearchTab, { index: restoringIndex });

		expect(
			screen.getByText(
				'Restoring this index from cold storage. Search will return when it is active.'
			)
		).toBeInTheDocument();
		await fireEvent.click(screen.getByRole('button', { name: 'Refresh status' }));
		expect(invalidateAllMock).toHaveBeenCalledOnce();
	});

	it('keeps a failed lifecycle refresh visible', async () => {
		invalidateAllMock.mockRejectedValueOnce(new Error('network unavailable'));
		const restoringIndex: Index = { ...activeIndex, tier: 'restoring' };
		render(SearchTab, { index: restoringIndex });

		await fireEvent.click(screen.getByRole('button', { name: 'Refresh status' }));

		expect(screen.getByRole('alert')).toHaveTextContent(
			'Could not refresh restore status. Try again.'
		);
		expect(screen.getByRole('button', { name: 'Refresh status' })).toBeEnabled();
	});

	it('shows provisioning message when endpoint is null', () => {
		const noEndpoint: Index = { ...activeIndex, endpoint: null };
		render(SearchTab, { index: noEndpoint });

		expect(screen.getByText(/provisioned/i)).toBeInTheDocument();
	});

	it('renders Search without Generate Preview Key', () => {
		render(SearchTab, { index: activeIndex });

		expect(screen.getByTestId('search-section')).toHaveAttribute(
			'data-documents-callback',
			'missing'
		);
		expect(screen.queryByRole('button', { name: /generate preview key/i })).not.toBeInTheDocument();
		expect(screen.getByTestId('instantsearch-widget')).toBeInTheDocument();
		expect(screen.getByLabelText('Search preview query')).toBeInTheDocument();
		expect(screen.getAllByRole('heading', { name: 'Search' })).toHaveLength(1);
		expect(screen.queryByRole('button', { name: 'Display preferences' })).not.toBeInTheDocument();
		expect(screen.getByLabelText('Search as you type')).toBeInTheDocument();
	});

	it('passes the raw index name as the same-origin proxy route for tenant-scoped preview hits', async () => {
		stubBrowserSearch([
			{ objectID: 'algolia_refugee_001', title: 'Blue Ridge trail running vest' }
		]);

		render(SearchTab, {
			index: {
				...activeIndex,
				name: 'c995f90d22db45f4a3c201dace264951_products',
				endpoint: 'http://vm-shared-f2b9c8a6.flapjack.foo:7700'
			},
			rawIndexName: 'products'
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, {
			target: { value: 'Blue Ridge' }
		});
		await fireEvent.keyDown(queryInput, { key: 'Enter' });

		expect(await screen.findByText('Blue Ridge trail running vest')).toBeInTheDocument();
		expect(globalThis.fetch).toHaveBeenCalledWith('/api/search/products', expect.any(Object));
		expect(
			JSON.parse((globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0][1].body)
		).toEqual({
			requests: [
				{
					indexName: 'products',
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

	it('renders a Merchandising mode toggle in the search preview header', () => {
		render(SearchTab, { index: activeIndex });

		const header = screen.getByTestId('search-preview-header');
		expect(header).toBeInTheDocument();
		const merchToggle = screen.getByLabelText('Merchandising mode');
		expect(merchToggle).toBeInTheDocument();
		expect(header.contains(merchToggle)).toBe(true);
		expect(screen.getByLabelText('Record preview activity in Analytics')).toBeInTheDocument();
	});

	it('hides merch controls on document cards when merch mode is OFF', async () => {
		stubBrowserSearch([{ objectID: 'hit-1', title: 'Merch test item' }]);

		render(SearchTab, {
			index: activeIndex
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'Merch' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		expect(await screen.findByText('Merch test item')).toBeInTheDocument();

		expect(screen.queryByTestId('card-merch-pin')).not.toBeInTheDocument();
		expect(screen.queryByTestId('card-merch-promote')).not.toBeInTheDocument();
		expect(screen.queryByTestId('card-merch-bury')).not.toBeInTheDocument();
	});

	it('shows merch controls on document cards when merch mode is ON', async () => {
		stubBrowserSearch([{ objectID: 'hit-1', title: 'Merch test item' }]);

		render(SearchTab, {
			index: activeIndex
		});

		const merchToggle = screen.getByLabelText('Merchandising mode');
		await fireEvent.click(merchToggle);

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'Merch' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		expect(await screen.findByText('Merch test item')).toBeInTheDocument();

		expect(screen.getByTestId('card-merch-pin')).toBeInTheDocument();
		expect(screen.getByTestId('card-merch-promote')).toBeInTheDocument();
		expect(screen.getByTestId('card-merch-bury')).toBeInTheDocument();
	});

	it('preserves merch mode ON across query re-renders', async () => {
		vi.stubGlobal('location', {
			href: 'https://cloud.staging.flapjack.foo/console/indexes/products?tab=search',
			protocol: 'https:'
		});
		vi.spyOn(window.history, 'replaceState').mockImplementation(() => {});
		let callCount = 0;
		vi.stubGlobal(
			'fetch',
			vi.fn().mockImplementation(async () => {
				callCount++;
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
								hits: [
									{
										objectID: `hit-${callCount}`,
										title: `Result ${callCount}`
									}
								]
							}
						]
					})
				};
			})
		);

		render(SearchTab, {
			index: activeIndex
		});

		const merchToggle = screen.getByLabelText('Merchandising mode');
		await fireEvent.click(merchToggle);

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'first' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		expect(await screen.findByText('Result 1')).toBeInTheDocument();
		expect(screen.getByTestId('card-merch-pin')).toBeInTheDocument();

		await fireEvent.input(queryInput, { target: { value: 'second' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		expect(await screen.findByText('Result 2')).toBeInTheDocument();

		expect((screen.getByLabelText('Merchandising mode') as HTMLInputElement).checked).toBe(true);
		expect(screen.getByTestId('card-merch-pin')).toBeInTheDocument();
		expect(screen.getByTestId('card-merch-promote')).toBeInTheDocument();
		expect(screen.getByTestId('card-merch-bury')).toBeInTheDocument();
	});

	it('derives pinnedPositions from rules prop and renders badge on matching hits', async () => {
		stubBrowserSearch([
			{ objectID: 'doc-1', title: 'Pinned item' },
			{ objectID: 'doc-2', title: 'Normal item' }
		]);

		render(SearchTab, {
			index: activeIndex,
			rules: {
				hits: [
					{
						objectID: 'r1',
						conditions: [],
						consequence: { promote: [{ objectID: 'doc-1', position: 4 }] }
					}
				],
				nbHits: 1,
				page: 0,
				nbPages: 1,
				totalNbHits: 1,
				query: ''
			}
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'test' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		expect(await screen.findByText('Pinned item')).toBeInTheDocument();

		const badges = screen.getAllByTestId('card-pinned-badge');
		expect(badges).toHaveLength(1);
		expect(badges[0].textContent).toMatch(/4/);
	});

	it('skips non-positional and malformed rule entries while preserving first match order', async () => {
		stubBrowserSearch([
			{ objectID: 'doc-1', title: 'First pin wins' },
			{ objectID: 'doc-2', title: 'Promote to top' },
			{ objectID: 'doc-3', title: 'Hidden only' },
			{ objectID: 'doc-4', title: 'Malformed pin' }
		]);

		render(SearchTab, {
			index: activeIndex,
			rules: {
				hits: [
					{
						objectID: 'r1',
						conditions: [],
						consequence: {
							promote: [
								{ objectID: 'doc-1', position: 4 },
								{ objectID: 'doc-2', position: 0 },
								{ objectID: 'doc-4', position: '2' },
								{ objectID: 123, position: 5 }
							],
							hide: [{ objectID: 'doc-3' }]
						}
					},
					{
						objectID: 'r2',
						conditions: [],
						consequence: { promote: [{ objectID: 'doc-1', position: 9 }] }
					}
				],
				nbHits: 2,
				page: 0,
				nbPages: 1,
				totalNbHits: 2,
				query: ''
			}
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'test' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		expect(await screen.findByText('First pin wins')).toBeInTheDocument();

		const badges = screen.getAllByTestId('card-pinned-badge');
		expect(badges).toHaveLength(1);
		expect(badges[0]).toHaveTextContent('Pinned #4');
	});

	it('yields no badges when rules is null', async () => {
		stubBrowserSearch([{ objectID: 'doc-1', title: 'Test item' }]);

		render(SearchTab, {
			index: activeIndex,
			rules: null
		});

		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'test' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		expect(await screen.findByText('Test item')).toBeInTheDocument();

		expect(screen.queryByTestId('card-pinned-badge')).toBeNull();
	});

	it('uses route-owned documents callback from the Search header button', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue({
				ok: true,
				status: 200,
				json: async () => ({
					results: [
						{
							nbHits: 1,
							processingTimeMS: 5,
							page: 1,
							totalPages: 1,
							hits: [{ objectID: 'doc-1', title: 'Rust Guide' }]
						}
					]
				})
			})
		);
		const onRequestDocumentsTab = vi.fn();
		render(SearchTab, {
			index: activeIndex,
			onRequestDocumentsTab
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Add documents' }));
		expect(onRequestDocumentsTab).toHaveBeenCalledTimes(1);
	});
});
