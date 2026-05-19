import { afterEach, describe, expect, it, vi } from 'vitest';
import { seedSearchableIndexForCustomer } from '../../tests/fixtures/searchable-index';

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
