import { afterEach, describe, expect, it, vi } from 'vitest';

import {
	FLAPJACK_SEARCH_APP_ID,
	buildFlapjackSearchClientOptions,
	buildFlapjackSearchHost,
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
		expect(buildFlapjackSearchClientOptions('https://vm-abc.flapjack.foo', 'fj_search_123')).toEqual({
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

	it('creates a custom InstantSearch client that posts batch queries to Flapjack', async () => {
		const fetchMock = vi.fn().mockResolvedValue({
			ok: true,
			json: async () => ({ results: [{ hits: [{ title: 'Rust Programming Language' }] }] })
		});
		vi.stubGlobal('fetch', fetchMock);

		const client = createFlapjackInstantSearchClient('http://127.0.0.1:7700/', 'fj_search_123');
		const result = await client.search([
			{ indexName: 'cust_products', params: 'query=Rust' }
		]);

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

	it('returns an empty result set when InstantSearch sends no requests', async () => {
		const fetchMock = vi.fn();
		vi.stubGlobal('fetch', fetchMock);

		const client = createFlapjackInstantSearchClient('http://127.0.0.1:7700', 'fj_search_123');

		await expect(client.search([])).resolves.toEqual({ results: [] });
		expect(fetchMock).not.toHaveBeenCalled();
	});
});
