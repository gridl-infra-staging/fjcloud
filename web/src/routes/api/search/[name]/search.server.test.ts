import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const { testSearchMock, createApiClientMock } = vi.hoisted(() => {
	const testSearchMock = vi.fn();
	const createApiClientMock = vi.fn(() => ({ testSearch: testSearchMock }));
	return { testSearchMock, createApiClientMock };
});

vi.mock('$lib/server/api', () => ({ createApiClient: createApiClientMock }));

import { POST } from './+server';

function makeRequestEvent(
	body: unknown,
	options: { user?: { token: string; customerId?: string } | null; name?: string } = {}
): unknown {
	const user = options.user === undefined ? { token: 'jwt-token' } : options.user;
	const name = options.name ?? 'products';
	return {
		request: new Request(`http://localhost/api/search/${name}`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body)
		}),
		locals: { user },
		params: { name }
	} as never;
}

function makeRawRequestEvent(rawBody: string): unknown {
	return {
		request: new Request('http://localhost/api/search/products', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: rawBody
		}),
		locals: { user: { token: 'jwt-token' } },
		params: { name: 'products' }
	} as never;
}

describe('POST /api/search/[name]', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('rejects unauthenticated requests with 401', async () => {
		const response = await POST(
			makeRequestEvent(
				{ requests: [{ indexName: 'products', params: { query: 'test' } }] },
				{ user: null }
			) as never
		);

		expect(response.status).toBe(401);
		expect(await response.json()).toEqual({ error: 'unauthorized' });
		expect(createApiClientMock).not.toHaveBeenCalled();
	});

	it('searches through the dashboard session without a preview key', async () => {
		const result = {
			hits: [{ objectID: '1', title: 'Rust Guide' }],
			nbHits: 1,
			page: 0,
			hitsPerPage: 20,
			processingTimeMS: 3,
			facets: { category: { Books: 1 } },
			queryID: 'query-123'
		};
		testSearchMock.mockResolvedValue(result);

		const response = await POST(
			makeRequestEvent({
				requests: [
					{
						indexName: 'products',
						params: {
							query: 'Rust',
							page: 0,
							hitsPerPage: 20,
							facets: ['category'],
							facetFilters: [['category:Books']],
							attributesToHighlight: ['title']
						}
					}
				]
			}) as never
		);

		expect(createApiClientMock).toHaveBeenCalledWith('jwt-token');
		expect(testSearchMock).toHaveBeenCalledWith('products', {
			query: 'Rust',
			page: 0,
			hitsPerPage: 20,
			facets: ['category'],
			facetFilters: [['category:Books']],
			attributesToHighlight: ['title']
		});
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ results: [result] });
	});

	it('preserves ordered batch results without unbounded fanout', async () => {
		const resolvers: Array<(value: { hits: never[]; nbHits: number }) => void> = [];
		let activeCalls = 0;
		let maximumActiveCalls = 0;
		testSearchMock.mockImplementation(
			() =>
				new Promise((resolve) => {
					activeCalls += 1;
					maximumActiveCalls = Math.max(maximumActiveCalls, activeCalls);
					resolvers.push((value) => {
						activeCalls -= 1;
						resolve(value);
					});
				})
		);

		const responsePromise = POST(
			makeRequestEvent({
				requests: [
					{ indexName: 'products', params: { query: 'first' } },
					{ indexName: 'products', params: { query: 'second' } }
				]
			}) as never
		);
		await vi.waitFor(() => expect(resolvers).toHaveLength(1));
		resolvers[0]({ hits: [], nbHits: 1 });
		await vi.waitFor(() => expect(resolvers).toHaveLength(2));
		resolvers[1]({ hits: [], nbHits: 2 });

		const response = await responsePromise;
		expect(maximumActiveCalls).toBe(1);
		expect(testSearchMock.mock.calls.map((call) => call[1])).toEqual([
			{ query: 'first' },
			{ query: 'second' }
		]);
		expect(await response.json()).toEqual({
			results: [
				{ hits: [], nbHits: 1 },
				{ hits: [], nbHits: 2 }
			]
		});
	});

	it('rejects cross-tenant search body substitution', async () => {
		const response = await POST(
			makeRequestEvent({
				requests: [{ indexName: 'another_customer_products', params: { query: 'secret' } }]
			}) as never
		);

		expect(response.status).toBe(400);
		expect(await response.json()).toEqual({ error: 'invalid search payload' });
		expect(testSearchMock).not.toHaveBeenCalled();
	});

	it('rejects batches above the fixed request cap', async () => {
		const requests = Array.from({ length: 11 }, (_, index) => ({
			indexName: 'products',
			params: { query: `query-${index}` }
		}));
		const response = await POST(makeRequestEvent({ requests }) as never);

		expect(response.status).toBe(400);
		expect(await response.json()).toEqual({ error: 'too many search requests' });
		expect(testSearchMock).not.toHaveBeenCalled();
	});

	it('preserves authenticated API lifecycle errors', async () => {
		testSearchMock.mockRejectedValue(new ApiRequestError(409, 'index is restoring'));
		const response = await POST(
			makeRequestEvent({
				requests: [{ indexName: 'products', params: { query: 'test' } }]
			}) as never
		);

		expect(response.status).toBe(409);
		expect(await response.json()).toEqual({ error: 'index is restoring' });
	});

	it('does not expose an internal Flapjack 404 to the customer', async () => {
		testSearchMock.mockRejectedValue(new ApiRequestError(404, 'Flapjack search failed: 404'));
		const response = await POST(
			makeRequestEvent({
				requests: [{ indexName: 'products', params: { query: 'test' } }]
			}) as never
		);

		expect(response.status).toBe(404);
		expect(await response.json()).toEqual({
			error: 'Search data is unavailable for this index. Refresh and retry.'
		});
	});

	it.each([
		['malformed JSON', makeRawRequestEvent('{invalid-json')],
		['missing requests', makeRequestEvent({})],
		['non-array requests', makeRequestEvent({ requests: {} })],
		['missing params', makeRequestEvent({ requests: [{ indexName: 'products' }] })]
	])('returns 400 for %s', async (_caseName, event) => {
		const response = await POST(event as never);
		expect(response.status).toBe(400);
		expect(await response.json()).toEqual({ error: 'invalid search payload' });
		expect(testSearchMock).not.toHaveBeenCalled();
	});

	it('returns 500 for unexpected API errors', async () => {
		testSearchMock.mockRejectedValue(new Error('network timeout'));
		const response = await POST(
			makeRequestEvent({
				requests: [{ indexName: 'products', params: { query: 'test' } }]
			}) as never
		);

		expect(response.status).toBe(500);
		expect(await response.json()).toEqual({ error: 'network timeout' });
	});
});
