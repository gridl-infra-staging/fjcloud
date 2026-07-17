import { afterEach, describe, expect, it, vi } from 'vitest';

import {
	FLAPJACK_SEARCH_APP_ID,
	buildFlapjackSearchClientOptions,
	buildFlapjackSearchHost,
	buildSearchPreviewParams,
	createDashboardInstantSearchClient,
	parseFlapjackSearchEndpoint
} from './flapjack-search-client';

afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

describe('flapjack-search-client', () => {
	it('keeps the public SDK app id and endpoint helpers separate from dashboard transport', () => {
		expect(FLAPJACK_SEARCH_APP_ID).toBe('flapjack');
		expect(parseFlapjackSearchEndpoint('http://127.0.0.1:7700')).toEqual({
			host: '127.0.0.1:7700',
			protocol: 'http'
		});
		expect(parseFlapjackSearchEndpoint('https://vm-abc.flapjack.foo')).toEqual({
			host: 'vm-abc.flapjack.foo',
			protocol: 'https'
		});
		expect(buildFlapjackSearchHost('http://127.0.0.1:7700')).toEqual({
			url: '127.0.0.1:7700',
			accept: 'readWrite',
			protocol: 'http'
		});
		expect(buildFlapjackSearchClientOptions('https://vm-abc.flapjack.foo', 'sdk-key')).toEqual({
			hosts: [{ url: 'vm-abc.flapjack.foo', accept: 'readWrite', protocol: 'https' }],
			baseHeaders: { Authorization: 'Bearer sdk-key' }
		});
	});

	it('rejects unsupported public SDK endpoint protocols', () => {
		expect(() => parseFlapjackSearchEndpoint('ftp://vm-abc.flapjack.foo')).toThrow(
			'Unsupported endpoint protocol: ftp:'
		);
	});

	it('builds canonical preview params for richer search requests', () => {
		expect(
			buildSearchPreviewParams({
				query: 'Rust',
				facets: ['brand', 'category'],
				facetFilters: [['brand:Acme'], ['category:Books']],
				filters: 'published = true',
				page: 2,
				hitsPerPage: 20,
				attributesToHighlight: ['title', 'body']
			})
		).toBe(
			'query=Rust&facets=%5B%22brand%22%2C%22category%22%5D&facetFilters=%5B%5B%22brand%3AAcme%22%5D%2C%5B%22category%3ABooks%22%5D%5D&filters=published+%3D+true&page=2&hitsPerPage=20&attributesToHighlight=%5B%22title%22%2C%22body%22%5D'
		);
	});

	it('posts dashboard search through same origin without any engine credential', async () => {
		const fetchMock = vi.fn().mockResolvedValue({
			ok: true,
			json: async () => ({ results: [{ hits: [{ title: 'Blue Ridge vest' }] }] })
		});
		vi.stubGlobal('fetch', fetchMock);
		const client = createDashboardInstantSearchClient('products');

		await client.search([{ indexName: 'products', params: 'query=Blue+Ridge&page=0' }]);

		expect(fetchMock).toHaveBeenCalledWith('/api/search/products', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				requests: [{ indexName: 'products', params: { query: 'Blue Ridge', page: 0 } }]
			})
		});
		const serializedRequest = JSON.stringify(fetchMock.mock.calls[0]);
		expect(serializedRequest).not.toContain('Authorization');
		expect(serializedRequest).not.toContain('X-Algolia-API-Key');
	});

	it('preserves structured proxy params for facets and highlighting', async () => {
		const fetchMock = vi.fn().mockResolvedValue({
			ok: true,
			json: async () => ({ results: [{ hits: [] }] })
		});
		vi.stubGlobal('fetch', fetchMock);
		const client = createDashboardInstantSearchClient('products');
		const params = buildSearchPreviewParams({
			query: 'refugee',
			page: 2,
			hitsPerPage: 5,
			facets: ['category'],
			facetFilters: [['category:docs'], ['status:published']],
			attributesToHighlight: ['title', 'body']
		});

		await client.search([{ indexName: 'products', params }]);

		expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({
			requests: [
				{
					indexName: 'products',
					params: {
						query: 'refugee',
						page: 2,
						hitsPerPage: 5,
						facets: ['category'],
						facetFilters: [['category:docs'], ['status:published']],
						attributesToHighlight: ['title', 'body']
					}
				}
			]
		});
	});

	it('same-origin analytics parameters remain booleans', async () => {
		const fetchMock = vi.fn().mockResolvedValue({
			ok: true,
			json: async () => ({ results: [{ hits: [] }] })
		});
		vi.stubGlobal('fetch', fetchMock);
		const client = createDashboardInstantSearchClient('products');

		await client.search([
			{
				indexName: 'products',
				params: buildSearchPreviewParams({
					query: 'rust',
					analytics: true,
					clickAnalytics: true
				})
			}
		]);

		expect(JSON.parse(fetchMock.mock.calls[0][1].body).requests[0].params).toMatchObject({
			analytics: true,
			clickAnalytics: true
		});
		expect(typeof JSON.parse(fetchMock.mock.calls[0][1].body).requests[0].params.analytics).toBe(
			'boolean'
		);
	});

	it('normalizes standard facets and drops undocumented compatibility aliases', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue({
				ok: true,
				json: async () => ({
					results: [
						{
							facets: { genre: { Action: 2, Drama: 3 } },
							facetDistribution: { genre: { Wrong: 99 } },
							facetsDistribution: { genre: { AlsoWrong: 98 } }
						}
					]
				})
			})
		);

		const response = await createDashboardInstantSearchClient('movies').search([
			{ indexName: 'movies', params: 'query=dark' }
		]);

		expect(response).toEqual({
			results: [{ facets: { genre: { Action: 2, Drama: 3 } } }]
		});
	});

	it('surfaces authenticated proxy errors without preview-key retries', async () => {
		const fetchMock = vi.fn().mockResolvedValue({ ok: false, status: 401 });
		vi.stubGlobal('fetch', fetchMock);
		const client = createDashboardInstantSearchClient('products');

		await expect(client.search([{ indexName: 'products', params: 'query=test' }])).rejects.toThrow(
			'Flapjack search failed: 401'
		);
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});

	it('returns an empty result set without issuing an empty search', async () => {
		const fetchMock = vi.fn();
		vi.stubGlobal('fetch', fetchMock);

		await expect(createDashboardInstantSearchClient('products').search([])).resolves.toEqual({
			results: []
		});
		expect(fetchMock).not.toHaveBeenCalled();
	});
});
