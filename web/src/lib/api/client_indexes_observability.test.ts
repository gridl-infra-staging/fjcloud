import { beforeEach, describe, expect, it } from 'vitest';
import { ApiClient } from './client';
import { BASE_URL, createAuthenticatedClient, mockFetch } from './client.test.shared';
import type { FlapjackApiKey, IndexInfrastructureResponse, IndexMetricsResponse } from './types';

describe('ApiClient - index observability and keys', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createAuthenticatedClient();
	});

	it('GET /indexes/:name/metrics returns the customer metrics response', async () => {
		const expected: IndexMetricsResponse = {
			index: 'products',
			documents_count: 1500,
			storage_bytes: 4096,
			search_requests_total: 9876,
			write_operations_total: 321,
			fetched_at: '2026-06-01T07:01:40Z'
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.getIndexMetrics('products');

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/metrics`, {
			method: 'GET',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
		});
		expect(result).toEqual(expected);
	});

	it('GET /indexes/:name/metrics encodes untrusted index names', async () => {
		const fetch = mockFetch(200, {
			index: 'products',
			documents_count: 0,
			storage_bytes: 0,
			search_requests_total: 0,
			write_operations_total: 0,
			fetched_at: '2026-06-01T07:01:40Z'
		});
		client.setFetch(fetch);

		await client.getIndexMetrics('../billing/subscription');

		expect(fetch).toHaveBeenCalledWith(
			`${BASE_URL}/indexes/..%2Fbilling%2Fsubscription/metrics`,
			expect.any(Object)
		);
	});

	it('GET /indexes/:name/infrastructure returns the customer infrastructure response', async () => {
		const expected: IndexInfrastructureResponse = {
			index: 'products',
			primary: {
				region: 'us-east-1',
				status: 'ready',
				utilization: 'yellow'
			},
			replicas: [
				{
					region: 'us-west-2',
					status: 'ready',
					lag_ops: 2,
					utilization: null
				}
			],
			footprint: {
				documents_count: 1500,
				storage_bytes: 4096,
				search_requests_total: 9876,
				write_operations_total: 321
			},
			headroom: 'busy',
			minimum_refresh_interval_seconds: 60
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.getIndexInfrastructure('products');

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/infrastructure`, {
			method: 'GET',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
		});
		expect(result).toEqual(expected);
	});

	it('GET /indexes/:name/infrastructure encodes untrusted index names', async () => {
		const fetch = mockFetch(200, {});
		client.setFetch(fetch);

		await client.getIndexInfrastructure('../billing/subscription');

		expect(fetch).toHaveBeenCalledWith(
			`${BASE_URL}/indexes/..%2Fbilling%2Fsubscription/infrastructure`,
			expect.any(Object)
		);
	});

	it('POST /indexes/:name/keys sends description and acl', async () => {
		const expected: FlapjackApiKey = {
			key: 'fj_search_abc123',
			createdAt: '2026-02-21T00:00:00Z'
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.createIndexKey('products', 'production key', ['search', 'browse']);

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/keys`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: JSON.stringify({ description: 'production key', acl: ['search', 'browse'] })
		});
		expect(result).toEqual(expected);
	});
});
