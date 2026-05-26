import { afterEach, describe, expect, it, vi } from 'vitest';

import {
	FLAPJACK_SEARCH_APP_ID,
	buildFlapjackSearchClientOptions,
	buildFlapjackSearchHost,
	buildSearchPreviewParams,
	createFlapjackInstantSearchClient,
	parseFlapjackSearchEndpoint
} from './flapjack-search-client';

afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

describe('flapjack-search-client', () => {
	it('exposes the shared search app id', () => {
		expect(FLAPJACK_SEARCH_APP_ID).toBe('griddle');
	});

	it('parses http endpoints while preserving host ports', () => {
		expect(parseFlapjackSearchEndpoint('http://127.0.0.1:7700')).toEqual({
			host: '127.0.0.1:7700',
			protocol: 'http'
		});
	});

	it('parses https endpoints', () => {
		expect(parseFlapjackSearchEndpoint('https://vm-abc.flapjack.foo')).toEqual({
			host: 'vm-abc.flapjack.foo',
			protocol: 'https'
		});
	});

	it('rejects unsupported protocols', () => {
		expect(() => parseFlapjackSearchEndpoint('ftp://vm-abc.flapjack.foo')).toThrow(
			'Unsupported endpoint protocol: ftp:'
		);
	});

	it('builds the shared browser host config', () => {
		expect(buildFlapjackSearchHost('http://127.0.0.1:7700')).toEqual({
			url: '127.0.0.1:7700',
			accept: 'readWrite',
			protocol: 'http'
		});
	});

	it('builds client options with the bearer auth contract used by the snippets', () => {
		expect(
			buildFlapjackSearchClientOptions('https://vm-abc.flapjack.foo', 'fj_search_123')
		).toEqual({
			hosts: [
				{
					url: 'vm-abc.flapjack.foo',
					accept: 'readWrite',
					protocol: 'https'
				}
			],
			baseHeaders: {
				Authorization: 'Bearer fj_search_123'
			}
		});
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

	it('creates a custom InstantSearch client that posts batch queries to Flapjack', async () => {
		const fetchMock = vi.fn().mockResolvedValue({
			ok: true,
			json: async () => ({ results: [{ hits: [{ title: 'Rust Programming Language' }] }] })
		});
		vi.stubGlobal('fetch', fetchMock);

		const client = createFlapjackInstantSearchClient('http://127.0.0.1:7700/', 'fj_search_123');
		const result = await client.search([{ indexName: 'cust_products', params: 'query=Rust' }]);

		expect(fetchMock).toHaveBeenCalledWith('http://127.0.0.1:7700/1/indexes/*/queries', {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				'X-Algolia-API-Key': 'fj_search_123',
				'X-Algolia-Application-Id': 'griddle',
				Authorization: 'Bearer fj_search_123'
			},
			body: JSON.stringify({
				requests: [{ indexName: 'cust_products', params: 'query=Rust' }]
			})
		});
		expect(result).toEqual({
			results: [{ hits: [{ title: 'Rust Programming Language' }] }]
		});
	});

	it('passes built params through unchanged as request.params', async () => {
		const fetchMock = vi.fn().mockResolvedValue({
			ok: true,
			json: async () => ({ results: [{ hits: [] }] })
		});
		vi.stubGlobal('fetch', fetchMock);

		const params = buildSearchPreviewParams({
			query: 'svelte',
			page: 1,
			hitsPerPage: 10
		});
		const client = createFlapjackInstantSearchClient('http://127.0.0.1:7700', 'fj_search_123');
		await client.search([{ indexName: 'cust_products', params }]);

		expect(fetchMock).toHaveBeenCalledWith('http://127.0.0.1:7700/1/indexes/*/queries', {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				'X-Algolia-API-Key': 'fj_search_123',
				'X-Algolia-Application-Id': 'griddle',
				Authorization: 'Bearer fj_search_123'
			},
			body: JSON.stringify({
				requests: [{ indexName: 'cust_products', params }]
			})
		});
	});

	it('returns an empty result set when InstantSearch sends no requests', async () => {
		const fetchMock = vi.fn();
		vi.stubGlobal('fetch', fetchMock);

		const client = createFlapjackInstantSearchClient('http://127.0.0.1:7700', 'fj_search_123');

		await expect(client.search([])).resolves.toEqual({ results: [] });
		expect(fetchMock).not.toHaveBeenCalled();
	});
});
