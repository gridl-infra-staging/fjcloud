import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const { testSearchMock, createApiClientMock } = vi.hoisted(() => {
	const testSearchMock = vi.fn();
	const createApiClientMock = vi.fn(() => ({
		testSearch: testSearchMock
	}));
	return { testSearchMock, createApiClientMock };
});

vi.mock('$lib/server/api', () => ({
	createApiClient: createApiClientMock
}));

import { POST } from './+server';

function makeRequestEvent(
	body: unknown,
	options: { user?: { token: string } | null; name?: string } = {}
): unknown {
	const user = options.user === undefined ? { token: 'jwt-token' } : options.user;
	const name = options.name ?? 'products';
	return {
		request: new Request('http://localhost/api/search/' + name, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body)
		}),
		locals: { user },
		params: { name }
	} as never;
}

function makeRawRequestEvent(
	rawBody: string,
	options: { user?: { token: string } | null; name?: string } = {}
): unknown {
	const user = options.user === undefined ? { token: 'jwt-token' } : options.user;
	const name = options.name ?? 'products';
	return {
		request: new Request('http://localhost/api/search/' + name, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: rawBody
		}),
		locals: { user },
		params: { name }
	} as never;
}

describe('POST /api/search/[name]', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('rejects unauthenticated requests with 401', async () => {
		const event = makeRequestEvent(
			{ requests: [{ indexName: 'products', params: { query: 'test' } }] },
			{ user: null }
		);

		const response = await POST(event as never);
		expect(response.status).toBe(401);

		const json = await response.json();
		expect(json.error).toBe('unauthorized');
		expect(testSearchMock).not.toHaveBeenCalled();
	});

	it('creates the API client with the authenticated user token', async () => {
		testSearchMock.mockResolvedValue({ hits: [], nbHits: 0 });

		const event = makeRequestEvent(
			{ requests: [{ indexName: 'products', params: { query: 'test' } }] },
			{ user: { token: 'my-secret-jwt' } }
		);

		await POST(event as never);

		expect(createApiClientMock).toHaveBeenCalledWith('my-secret-jwt');
	});

	it('derives index name from route params, not request body', async () => {
		testSearchMock.mockResolvedValue({
			hits: [{ objectID: '1', name: 'Widget' }],
			nbHits: 1,
			page: 0,
			hitsPerPage: 20
		});

		const event = makeRequestEvent(
			{
				requests: [
					{ indexName: 'attacker-controlled-index', params: { query: 'test' } }
				]
			},
			{ name: 'products' }
		);

		await POST(event as never);

		// Should call testSearch with route param 'products', not 'attacker-controlled-index'
		expect(testSearchMock).toHaveBeenCalledWith('products', expect.any(Object));
	});

	it('wraps upstream response in { results: [...] } for InstantSearch', async () => {
		const upstreamResult = {
			hits: [{ objectID: '1', name: 'Widget' }],
			nbHits: 1,
			page: 0,
			hitsPerPage: 20,
			processingTimeMS: 3,
			facets: { category: { electronics: 1 } }
		};
		testSearchMock.mockResolvedValue(upstreamResult);

		const event = makeRequestEvent({
			requests: [{ indexName: 'products', params: { query: 'widget', page: 0 } }]
		});

		const response = await POST(event as never);
		expect(response.status).toBe(200);

		const json = await response.json();
		expect(json.results).toHaveLength(1);
		expect(json.results[0]).toEqual(upstreamResult);
	});

	it('forwards structured search params from each request', async () => {
		testSearchMock.mockResolvedValue({ hits: [], nbHits: 0 });

		const event = makeRequestEvent({
			requests: [
				{
					indexName: 'products',
					params: {
						query: 'laptop',
						page: 2,
						hitsPerPage: 5,
						facets: ['category'],
						facetFilters: [['category:electronics']]
					}
				}
			]
		});

		await POST(event as never);

		expect(testSearchMock).toHaveBeenCalledWith('products', {
			query: 'laptop',
			page: 2,
			hitsPerPage: 5,
			facets: ['category'],
			facetFilters: [['category:electronics']]
		});
	});

	it('handles multiple requests in a single batch', async () => {
		testSearchMock
			.mockResolvedValueOnce({ hits: [{ objectID: '1' }], nbHits: 1 })
			.mockResolvedValueOnce({ hits: [], nbHits: 0 });

		const event = makeRequestEvent({
			requests: [
				{ indexName: 'products', params: { query: 'first' } },
				{ indexName: 'products', params: { query: 'second', page: 1 } }
			]
		});

		const response = await POST(event as never);
		const json = await response.json();

		expect(json.results).toHaveLength(2);
		expect(json.results[0].nbHits).toBe(1);
		expect(json.results[1].nbHits).toBe(0);
		expect(testSearchMock).toHaveBeenCalledTimes(2);
	});

	// --- Failure-path coverage (Item 6) ---

	it('preserves ApiRequestError status and message from upstream', async () => {
		testSearchMock.mockRejectedValue(new ApiRequestError(404, 'index not found'));

		const event = makeRequestEvent({
			requests: [{ indexName: 'products', params: { query: 'test' } }]
		});

		const response = await POST(event as never);
		expect(response.status).toBe(404);

		const json = await response.json();
		expect(json.error).toBe('index not found');
	});

	it('returns 500 for unexpected upstream errors', async () => {
		testSearchMock.mockRejectedValue(new Error('network timeout'));

		const event = makeRequestEvent({
			requests: [{ indexName: 'products', params: { query: 'test' } }]
		});

		const response = await POST(event as never);
		expect(response.status).toBe(500);

		const json = await response.json();
		expect(json.error).toBe('network timeout');
	});

	it('returns 400 for malformed JSON payloads', async () => {
		const event = makeRawRequestEvent('{invalid-json');

		const response = await POST(event as never);
		expect(response.status).toBe(400);

		const json = await response.json();
		expect(json.error).toBe('invalid search payload');
		expect(testSearchMock).not.toHaveBeenCalled();
	});

	it('returns 400 when requests is not an array', async () => {
		const event = makeRequestEvent({
			requests: { indexName: 'products', params: { query: 'test' } }
		});

		const response = await POST(event as never);
		expect(response.status).toBe(400);

		const json = await response.json();
		expect(json.error).toBe('invalid search payload');
		expect(testSearchMock).not.toHaveBeenCalled();
	});

	it('returns 400 when requests is missing', async () => {
		const event = makeRequestEvent({});

		const response = await POST(event as never);
		expect(response.status).toBe(400);

		const json = await response.json();
		expect(json.error).toBe('invalid search payload');
		expect(testSearchMock).not.toHaveBeenCalled();
	});

	it('returns 400 when a request omits params', async () => {
		const event = makeRequestEvent({
			requests: [{ indexName: 'products' }]
		});

		const response = await POST(event as never);
		expect(response.status).toBe(400);

		const json = await response.json();
		expect(json.error).toBe('invalid search payload');
		expect(testSearchMock).not.toHaveBeenCalled();
	});
});
