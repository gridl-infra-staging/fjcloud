import { afterEach, describe, expect, it, vi } from 'vitest';
import {
	createSeedSearchableIndexFactory,
	seedSearchableIndexForCustomer
} from '../../tests/fixtures/searchable-index';

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

function textResponse(body: string, status: number): Response {
	return new Response(body, { status });
}

describe('seedSearchableIndexForCustomer', () => {
	afterEach(() => {
		vi.restoreAllMocks();
	});

	it('survives prolonged transient 503s while creating index keys', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const indexName = 'retry-key-index';
		const expectedHitText = 'Retryable Search Hit';
		let keyCreateAttempts = 0;

		const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
			const requestUrl =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			const { pathname } = new URL(requestUrl);
			const method = (init?.method ?? 'GET').toUpperCase();

			if (method === 'POST' && pathname === '/admin/tenants/customer-1/indexes') {
				return textResponse('', 200);
			}

			if (method === 'GET' && pathname === `/indexes/${encodeURIComponent(indexName)}`) {
				return jsonResponse({ name: indexName }, 200);
			}

			if (method === 'POST' && pathname === `/indexes/${encodeURIComponent(indexName)}/keys`) {
				keyCreateAttempts += 1;
				if (keyCreateAttempts <= 6) {
					return textResponse('{"error":"backend temporarily unavailable"}', 503);
				}
				return jsonResponse({ key: 'test-key' }, 200);
			}

			if (
				method === 'POST' &&
				pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`
			) {
				return textResponse('', 200);
			}

			if (method === 'POST' && pathname === `/indexes/${encodeURIComponent(indexName)}/search`) {
				return jsonResponse({ hits: [{ title: expectedHitText }] }, 200);
			}

			throw new Error(`Unexpected request: ${method} ${pathname}`);
		}) as typeof fetch;

		await expect(
			seedSearchableIndexForCustomer({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: 'customer-1',
				token: 'customer-token',
				name: indexName,
				region: 'us-east-1',
				query: expectedHitText,
				expectedHitText,
				documents: [{ objectID: 'doc-1', title: expectedHitText }],
				fetchImpl
			})
		).resolves.toEqual({
			name: indexName,
			query: expectedHitText,
			expectedHitText
		});

		expect(keyCreateAttempts).toBe(7);
	});

	it('survives extended backend warmup windows for key creation', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const indexName = 'long-warmup-key-index';
		const expectedHitText = 'Long Warmup Search Hit';
		let keyCreateAttempts = 0;

		const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
			const requestUrl =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			const { pathname } = new URL(requestUrl);
			const method = (init?.method ?? 'GET').toUpperCase();

			if (method === 'POST' && pathname === '/admin/tenants/customer-1/indexes') {
				return textResponse('', 200);
			}

			if (method === 'GET' && pathname === `/indexes/${encodeURIComponent(indexName)}`) {
				return jsonResponse({ name: indexName }, 200);
			}

			if (method === 'POST' && pathname === `/indexes/${encodeURIComponent(indexName)}/keys`) {
				keyCreateAttempts += 1;
				if (keyCreateAttempts <= 15) {
					return new Response('{"error":"backend temporarily unavailable"}', {
						status: 503,
						headers: { 'retry-after': '1' }
					});
				}
				return jsonResponse({ key: 'test-key' }, 200);
			}

			if (
				method === 'POST' &&
				pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`
			) {
				return textResponse('', 200);
			}

			if (method === 'POST' && pathname === `/indexes/${encodeURIComponent(indexName)}/search`) {
				return jsonResponse({ hits: [{ title: expectedHitText }] }, 200);
			}

			throw new Error(`Unexpected request: ${method} ${pathname}`);
		}) as typeof fetch;

		await expect(
			seedSearchableIndexForCustomer({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: 'customer-1',
				token: 'customer-token',
				name: indexName,
				region: 'us-east-1',
				query: expectedHitText,
				expectedHitText,
				documents: [{ objectID: 'doc-1', title: expectedHitText }],
				fetchImpl
			})
		).resolves.toEqual({
			name: indexName,
			query: expectedHitText,
			expectedHitText
		});

		expect(keyCreateAttempts).toBe(16);
	});

	it('survives extended backend warmup windows for admin index creation', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const indexName = 'long-warmup-admin-create-index';
		const expectedHitText = 'Long Warmup Admin Create Hit';
		let adminCreateAttempts = 0;

		const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
			const requestUrl =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			const { pathname } = new URL(requestUrl);
			const method = (init?.method ?? 'GET').toUpperCase();

			if (method === 'POST' && pathname === '/admin/tenants/customer-1/indexes') {
				adminCreateAttempts += 1;
				if (adminCreateAttempts <= 8) {
					return new Response('{"error":"backend temporarily unavailable"}', {
						status: 503,
						headers: { 'retry-after': '1' }
					});
				}
				return textResponse('', 200);
			}

			if (method === 'GET' && pathname === `/indexes/${encodeURIComponent(indexName)}`) {
				return jsonResponse({ name: indexName }, 200);
			}

			if (method === 'POST' && pathname === `/indexes/${encodeURIComponent(indexName)}/keys`) {
				return jsonResponse({ key: 'test-key' }, 200);
			}

			if (
				method === 'POST' &&
				pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`
			) {
				return textResponse('', 200);
			}

			if (method === 'POST' && pathname === `/indexes/${encodeURIComponent(indexName)}/search`) {
				return jsonResponse({ hits: [{ title: expectedHitText }] }, 200);
			}

			throw new Error(`Unexpected request: ${method} ${pathname}`);
		}) as typeof fetch;

		await expect(
			seedSearchableIndexForCustomer({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: 'customer-1',
				token: 'customer-token',
				name: indexName,
				region: 'us-east-1',
				query: expectedHitText,
				expectedHitText,
				documents: [{ objectID: 'doc-1', title: expectedHitText }],
				fetchImpl
			})
		).resolves.toEqual({
			name: indexName,
			query: expectedHitText,
			expectedHitText
		});

		expect(adminCreateAttempts).toBe(9);
	});
});

describe('createSeedSearchableIndexFactory', () => {
	afterEach(() => {
		vi.restoreAllMocks();
	});

	it('writes default fixture documents with explicit objectID values', async () => {
		const indexName = 'factory-default-docs-object-id-index';
		const waitForSeededIndex = vi.fn(async () => undefined);
		const getCustomerId = vi.fn(async () => 'customer-1');
		const adminApiCall = vi.fn(async () => textResponse('', 200));
		const apiCall = vi.fn(async (method: string, path: string) => {
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
				return jsonResponse({ key: 'test-key' }, 200);
			}
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
				return jsonResponse({ hits: [{ title: 'Rust Programming Language' }] }, 200);
			}
			throw new Error(`Unexpected request: ${method} ${path}`);
		});

		let batchPayload: {
			requests: Array<{ action: string; body: Record<string, unknown> }>;
		} | null = null;
		vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: RequestInfo | URL, init) => {
			const requestUrl =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			const { pathname } = new URL(requestUrl);
			if (pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`) {
				batchPayload = JSON.parse(String(init?.body));
				return textResponse('', 200);
			}

			throw new Error(`Unexpected fetch request: ${pathname}`);
		});

		const seedSearchableIndex = createSeedSearchableIndexFactory({
			testRegion: 'us-east-1',
			apiCall,
			adminApiCall,
			getCustomerId,
			waitForSeededIndex,
			flapjackUrl: 'http://127.0.0.1:7700'
		});

		await seedSearchableIndex(indexName);
		expect(batchPayload).not.toBeNull();
		const capturedBatchPayload = batchPayload as unknown as {
			requests: Array<{ action: string; body: Record<string, unknown> }>;
		};
		const requestBodies = capturedBatchPayload.requests.map(
			(request: { body: Record<string, unknown> }) => {
				return request.body;
			}
		);
		expect(requestBodies).toHaveLength(3);
		for (const body of requestBodies) {
			expect(body.objectID).toEqual(expect.any(String));
		}
	});

	it('falls back to API batch ingestion when direct Flapjack ingest never becomes searchable', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const indexName = 'factory-flapjack-fallback-index';
		const waitForSeededIndex = vi.fn(async () => undefined);
		const getCustomerId = vi.fn(async () => 'customer-1');
		const adminApiCall = vi.fn(async () => textResponse('', 200));
		let apiBatchUsed = false;
		const apiCall = vi.fn(async (method: string, path: string, body?: unknown) => {
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
				return jsonResponse({ key: 'test-key' }, 200);
			}
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/batch`) {
				apiBatchUsed = true;
				expect(body).toMatchObject({
					requests: expect.arrayContaining([
						expect.objectContaining({
							action: 'addObject',
							body: expect.objectContaining({ objectID: expect.any(String) })
						})
					])
				});
				return textResponse('', 200);
			}
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
				return jsonResponse(
					{
						hits: apiBatchUsed ? [{ title: 'Rust Programming Language' }] : []
					},
					200
				);
			}
			throw new Error(`Unexpected request: ${method} ${path}`);
		});

		vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: RequestInfo | URL) => {
			const requestUrl =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			const { pathname } = new URL(requestUrl);
			if (pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`) {
				return textResponse('', 200);
			}
			throw new Error(`Unexpected fetch request: ${pathname}`);
		});

		const seedSearchableIndex = createSeedSearchableIndexFactory({
			testRegion: 'us-east-1',
			apiCall,
			adminApiCall,
			getCustomerId,
			waitForSeededIndex,
			flapjackUrl: 'http://127.0.0.1:7700'
		});

		await expect(seedSearchableIndex(indexName)).resolves.toEqual({
			name: indexName,
			query: 'Rust',
			expectedHitText: 'Rust Programming Language'
		});
		expect(apiBatchUsed).toBe(true);
	});

	it('rechecks search convergence when API batch fallback is quota-limited', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const indexName = 'factory-fallback-quota-recheck-index';
		const waitForSeededIndex = vi.fn(async () => undefined);
		const getCustomerId = vi.fn(async () => 'customer-1');
		const adminApiCall = vi.fn(async () => textResponse('', 200));
		let searchAttempts = 0;
		let apiBatchAttempts = 0;
		const apiCall = vi.fn(async (method: string, path: string) => {
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
				return jsonResponse({ key: 'test-key' }, 200);
			}
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/batch`) {
				apiBatchAttempts += 1;
				return textResponse('{"error":"quota_exceeded","limit":"max_records"}', 403);
			}
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
				searchAttempts += 1;
				return jsonResponse(
					{
						hits: searchAttempts >= 125 ? [{ title: 'Rust Programming Language' }] : []
					},
					200
				);
			}
			throw new Error(`Unexpected request: ${method} ${path}`);
		});

		vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: RequestInfo | URL) => {
			const requestUrl =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			const { pathname } = new URL(requestUrl);
			if (pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`) {
				return textResponse('', 200);
			}
			throw new Error(`Unexpected fetch request: ${pathname}`);
		});

		const seedSearchableIndex = createSeedSearchableIndexFactory({
			testRegion: 'us-east-1',
			apiCall,
			adminApiCall,
			getCustomerId,
			waitForSeededIndex,
			flapjackUrl: 'http://127.0.0.1:7700'
		});

		await expect(seedSearchableIndex(indexName)).resolves.toEqual({
			name: indexName,
			query: 'Rust',
			expectedHitText: 'Rust Programming Language'
		});
		expect(apiBatchAttempts).toBe(1);
		expect(searchAttempts).toBeGreaterThanOrEqual(125);
	});

	it('retries transient admin index creation failures before seeding documents', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const indexName = 'factory-admin-retry-index';
		let adminCreateAttempts = 0;
		const waitForSeededIndex = vi.fn(async () => undefined);
		const getCustomerId = vi.fn(async () => 'customer-1');
		const adminApiCall = vi.fn(async () => {
			adminCreateAttempts += 1;
			if (adminCreateAttempts <= 3) {
				return new Response('{"error":"backend temporarily unavailable"}', {
					status: 503,
					headers: { 'retry-after': '1' }
				});
			}
			return textResponse('', 200);
		});
		const apiCall = vi.fn(async (method: string, path: string) => {
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
				return jsonResponse({ key: 'test-key' }, 200);
			}

			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
				return jsonResponse({ hits: [{ title: 'Rust Programming Language' }] }, 200);
			}

			throw new Error(`Unexpected request: ${method} ${path}`);
		});
		vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: RequestInfo | URL) => {
			const requestUrl =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			const { pathname } = new URL(requestUrl);
			if (pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`) {
				return textResponse('', 200);
			}

			throw new Error(`Unexpected fetch request: ${pathname}`);
		});

		const seedSearchableIndex = createSeedSearchableIndexFactory({
			testRegion: 'us-east-1',
			apiCall,
			adminApiCall,
			getCustomerId,
			waitForSeededIndex,
			flapjackUrl: 'http://127.0.0.1:7700'
		});

		await expect(seedSearchableIndex(indexName)).resolves.toEqual({
			name: indexName,
			query: 'Rust',
			expectedHitText: 'Rust Programming Language'
		});

		expect(adminCreateAttempts).toBe(4);
		expect(waitForSeededIndex).toHaveBeenCalledWith(indexName);
	});
});
