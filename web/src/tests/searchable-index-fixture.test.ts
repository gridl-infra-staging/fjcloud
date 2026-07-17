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
		let keyCreated = false;

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
				keyCreated = true;
				return jsonResponse({ key: 'test-key' }, 200);
			}

			if (
				method === 'POST' &&
				pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`
			) {
				if (!keyCreated) {
					throw new Error('Batch ingest reached before index key creation recovered');
				}
				return textResponse('', 200);
			}

			if (method === 'POST' && pathname === `/indexes/${encodeURIComponent(indexName)}/search`) {
				if (!keyCreated) {
					throw new Error('Search reached before index key creation recovered');
				}
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
		let keyCreated = false;

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
				keyCreated = true;
				return jsonResponse({ key: 'test-key' }, 200);
			}

			if (
				method === 'POST' &&
				pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`
			) {
				if (!keyCreated) {
					throw new Error('Batch ingest reached before index key creation recovered');
				}
				return textResponse('', 200);
			}

			if (method === 'POST' && pathname === `/indexes/${encodeURIComponent(indexName)}/search`) {
				if (!keyCreated) {
					throw new Error('Search reached before index key creation recovered');
				}
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
	});

	it('survives extended endpoint-not-ready warmup windows for key creation', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const indexName = 'long-endpoint-not-ready-key-index';
		const expectedHitText = 'Endpoint Not Ready Search Hit';
		let keyCreateAttempts = 0;
		let keyCreated = false;

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
				if (keyCreateAttempts <= 25) {
					return textResponse('{"error":"endpoint not ready yet"}', 400);
				}
				keyCreated = true;
				return jsonResponse({ key: 'test-key' }, 200);
			}

			if (
				method === 'POST' &&
				pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`
			) {
				if (!keyCreated) {
					throw new Error('Batch ingest reached before index key creation recovered');
				}
				return textResponse('', 200);
			}

			if (method === 'POST' && pathname === `/indexes/${encodeURIComponent(indexName)}/search`) {
				if (!keyCreated) {
					throw new Error('Search reached before index key creation recovered');
				}
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
	});

	it('forwards loopback flapjackUrl as admin flapjack_url and uses direct Flapjack ingestion', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const indexName = 'loopback-direct-engine-index';
		const expectedHitText = 'Loopback Search Hit';
		const loopbackFlapjackUrl = 'http://127.0.0.1:7700';
		let adminCreateBody: Record<string, unknown> | null = null;
		let flapjackEngineCalled = false;
		let apiBatchCalled = false;

		const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
			const requestUrl =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			const parsedUrl = new URL(requestUrl);
			const method = (init?.method ?? 'GET').toUpperCase();
			const path = parsedUrl.pathname;

			if (
				parsedUrl.origin === 'http://localhost:3001' &&
				method === 'POST' &&
				path === '/admin/tenants/customer-1/indexes'
			) {
				adminCreateBody = init?.body ? JSON.parse(String(init.body)) : null;
				return jsonResponse({}, 200);
			}
			if (
				parsedUrl.origin === 'http://localhost:3001' &&
				method === 'GET' &&
				path === `/indexes/${encodeURIComponent(indexName)}`
			) {
				return jsonResponse({ name: indexName }, 200);
			}
			if (
				parsedUrl.origin === 'http://localhost:3001' &&
				method === 'POST' &&
				path === `/indexes/${encodeURIComponent(indexName)}/keys`
			) {
				return jsonResponse({ key: 'loopback-test-key' }, 200);
			}
			if (
				parsedUrl.origin === loopbackFlapjackUrl &&
				path === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`
			) {
				flapjackEngineCalled = true;
				return jsonResponse({}, 200);
			}
			if (
				parsedUrl.origin === 'http://localhost:3001' &&
				method === 'POST' &&
				path === `/indexes/${encodeURIComponent(indexName)}/batch`
			) {
				apiBatchCalled = true;
				return jsonResponse({}, 200);
			}
			if (
				parsedUrl.origin === 'http://localhost:3001' &&
				method === 'POST' &&
				path === `/indexes/${encodeURIComponent(indexName)}/search`
			) {
				return jsonResponse(
					{ hits: flapjackEngineCalled ? [{ title: expectedHitText }] : [] },
					200
				);
			}
			throw new Error(`Unexpected request: ${method} ${parsedUrl.origin}${path}`);
		}) as typeof fetch;

		await expect(
			seedSearchableIndexForCustomer({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: 'customer-1',
				token: 'customer-token',
				name: indexName,
				region: 'us-east-1',
				flapjackUrl: loopbackFlapjackUrl,
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

		expect(adminCreateBody).not.toBeNull();
		expect(adminCreateBody).toMatchObject({ flapjack_url: loopbackFlapjackUrl });
		expect(flapjackEngineCalled).toBe(true);
		expect(apiBatchCalled).toBe(false);
	});

	it('skips public API origin as admin flapjack_url and avoids API-host direct Flapjack ingestion in remote-target mode', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const previousRemoteFlag = process.env.PLAYWRIGHT_TARGET_REMOTE;
		process.env.PLAYWRIGHT_TARGET_REMOTE = '1';
		try {
			const indexName = 'remote-staging-fixture-index';
			const expectedHitText = 'Remote Staging Hit';
			const remoteApiOrigin = 'https://api.staging.flapjack.foo';
			let adminCreateBody: Record<string, unknown> | null = null;
			let customerCreateBody: Record<string, unknown> | null = null;
			let apiBatchPayload: { requests: Array<{ action: string; body: unknown }> } | null = null;
			let directFlapjackIngestAttempted = false;
			let keyCreateAttempts = 0;

			const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
				const requestUrl =
					typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
				const parsedUrl = new URL(requestUrl);
				const method = (init?.method ?? 'GET').toUpperCase();
				const path = parsedUrl.pathname;

				if (path === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`) {
					directFlapjackIngestAttempted = true;
					return jsonResponse({}, 200);
				}

				if (parsedUrl.origin !== remoteApiOrigin) {
					throw new Error(
						`Unexpected non-API origin in remote-target mode: ${parsedUrl.origin}${path}`
					);
				}

				if (method === 'POST' && path === '/admin/tenants/customer-1/indexes') {
					adminCreateBody = init?.body ? JSON.parse(String(init.body)) : null;
					return jsonResponse({}, 200);
				}
				if (method === 'POST' && path === '/indexes') {
					customerCreateBody = init?.body ? JSON.parse(String(init.body)) : null;
					return jsonResponse({ name: indexName }, 201);
				}
				if (method === 'GET' && path === `/indexes/${encodeURIComponent(indexName)}`) {
					return jsonResponse({ name: indexName }, 200);
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
					keyCreateAttempts += 1;
					throw new Error('remote API-batch seed must not create an unused index key');
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/batch`) {
					apiBatchPayload = init?.body
						? (JSON.parse(String(init.body)) as {
								requests: Array<{ action: string; body: unknown }>;
							})
						: null;
					return jsonResponse({}, 200);
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
					return jsonResponse({ hits: apiBatchPayload ? [{ title: expectedHitText }] : [] }, 200);
				}
				throw new Error(`Unexpected request: ${method} ${parsedUrl.origin}${path}`);
			}) as typeof fetch;

			await expect(
				seedSearchableIndexForCustomer({
					apiUrl: remoteApiOrigin,
					adminKey: 'admin-key',
					customerId: 'customer-1',
					token: 'customer-token',
					name: indexName,
					region: 'us-east-1',
					flapjackUrl: remoteApiOrigin,
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

			expect(adminCreateBody).toBeNull();
			expect(customerCreateBody).toEqual({ name: indexName, region: 'us-east-1' });
			expect(directFlapjackIngestAttempted).toBe(false);
			// Branch not taken: remote API-batch seeding must not create an unused index key.
			expect(keyCreateAttempts).toBe(0);
			expect(apiBatchPayload).not.toBeNull();
			expect(apiBatchPayload).toMatchObject({
				requests: expect.arrayContaining([
					expect.objectContaining({
						action: 'addObject',
						body: expect.objectContaining({ objectID: 'doc-1' })
					})
				])
			});
		} finally {
			if (previousRemoteFlag === undefined) {
				delete process.env.PLAYWRIGHT_TARGET_REMOTE;
			} else {
				process.env.PLAYWRIGHT_TARGET_REMOTE = previousRemoteFlag;
			}
		}
	});

	it('uses customer API batch seeding when remote-target mode omits FLAPJACK_URL', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const previousRemoteFlag = process.env.PLAYWRIGHT_TARGET_REMOTE;
		const previousFlapjackUrl = process.env.FLAPJACK_URL;
		process.env.PLAYWRIGHT_TARGET_REMOTE = '1';
		delete process.env.FLAPJACK_URL;
		try {
			const indexName = 'remote-no-flapjack-url-index';
			const expectedHitText = 'Remote Defaultless Hit';
			const remoteApiOrigin = 'https://api.staging.flapjack.foo';
			let customerCreateAttempts = 0;
			let keyCreateAttempts = 0;
			let apiBatchAttempts = 0;
			let directFlapjackIngestAttempted = false;

			const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
				const requestUrl =
					typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
				const parsedUrl = new URL(requestUrl);
				const method = (init?.method ?? 'GET').toUpperCase();
				const path = parsedUrl.pathname;

				if (path === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`) {
					directFlapjackIngestAttempted = true;
					return jsonResponse({}, 200);
				}

				if (parsedUrl.origin !== remoteApiOrigin) {
					throw new Error(
						`Unexpected non-API origin in remote-target mode: ${parsedUrl.origin}${path}`
					);
				}

				if (method === 'POST' && path === '/indexes') {
					customerCreateAttempts += 1;
					return jsonResponse({ name: indexName }, 201);
				}
				if (method === 'GET' && path === `/indexes/${encodeURIComponent(indexName)}`) {
					return jsonResponse({ name: indexName }, 200);
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
					keyCreateAttempts += 1;
					throw new Error('remote API-batch seed must not create an unused index key');
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/batch`) {
					apiBatchAttempts += 1;
					return jsonResponse({}, 200);
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
					return jsonResponse(
						{ hits: apiBatchAttempts > 0 ? [{ title: expectedHitText }] : [] },
						200
					);
				}
				throw new Error(`Unexpected request: ${method} ${parsedUrl.origin}${path}`);
			}) as typeof fetch;

			await expect(
				seedSearchableIndexForCustomer({
					apiUrl: remoteApiOrigin,
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
			// Branch contract: remote mode without FLAPJACK_URL creates the customer index once.
			expect(customerCreateAttempts).toBe(1);
			// Branch not taken: remote API-batch seeding must not create an unused index key.
			expect(keyCreateAttempts).toBe(0);
			// No re-submit: the customer API-batch ingest should happen exactly once.
			expect(apiBatchAttempts).toBe(1);
			expect(directFlapjackIngestAttempted).toBe(false);
		} finally {
			if (previousRemoteFlag === undefined) {
				delete process.env.PLAYWRIGHT_TARGET_REMOTE;
			} else {
				process.env.PLAYWRIGHT_TARGET_REMOTE = previousRemoteFlag;
			}
			if (previousFlapjackUrl === undefined) {
				delete process.env.FLAPJACK_URL;
			} else {
				process.env.FLAPJACK_URL = previousFlapjackUrl;
			}
		}
	});

	it('creates remote API-batch indexes through the customer route so they are placed before ingest', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const previousRemoteFlag = process.env.PLAYWRIGHT_TARGET_REMOTE;
		process.env.PLAYWRIGHT_TARGET_REMOTE = '1';
		try {
			const indexName = 'remote-customer-created-index';
			const expectedHitText = 'Remote Customer Route Hit';
			const remoteApiOrigin = 'https://api.staging.flapjack.foo';
			let adminCreateAttempts = 0;
			let customerCreateBody: Record<string, unknown> | null = null;
			let apiBatchPayload: { requests: Array<{ action: string; body: unknown }> } | null = null;

			const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
				const requestUrl =
					typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
				const parsedUrl = new URL(requestUrl);
				const method = (init?.method ?? 'GET').toUpperCase();
				const path = parsedUrl.pathname;

				if (parsedUrl.origin !== remoteApiOrigin) {
					throw new Error(
						`Unexpected non-API origin in remote-target mode: ${parsedUrl.origin}${path}`
					);
				}

				if (method === 'POST' && path === '/admin/tenants/customer-1/indexes') {
					adminCreateAttempts += 1;
					throw new Error('remote API-batch seed must not use admin placeholder seeding');
				}
				if (method === 'POST' && path === '/indexes') {
					customerCreateBody = init?.body ? JSON.parse(String(init.body)) : null;
					return jsonResponse({ name: indexName }, 201);
				}
				if (method === 'GET' && path === `/indexes/${encodeURIComponent(indexName)}`) {
					return jsonResponse({ name: indexName }, 200);
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
					throw new Error('remote API-batch seed must not create an unused index key');
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/batch`) {
					apiBatchPayload = init?.body
						? (JSON.parse(String(init.body)) as {
								requests: Array<{ action: string; body: unknown }>;
							})
						: null;
					return jsonResponse({}, 200);
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
					return jsonResponse({ hits: apiBatchPayload ? [{ title: expectedHitText }] : [] }, 200);
				}
				throw new Error(`Unexpected request: ${method} ${parsedUrl.origin}${path}`);
			}) as typeof fetch;

			await expect(
				seedSearchableIndexForCustomer({
					apiUrl: remoteApiOrigin,
					adminKey: 'admin-key',
					customerId: 'customer-1',
					token: 'customer-token',
					name: indexName,
					region: 'us-east-1',
					flapjackUrl: remoteApiOrigin,
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
			// Branch not taken: remote API-batch seeding must not use admin placeholder seeding.
			expect(adminCreateAttempts).toBe(0);
			expect(customerCreateBody).toEqual({ name: indexName, region: 'us-east-1' });
			expect(apiBatchPayload).toMatchObject({
				requests: [
					expect.objectContaining({
						action: 'addObject',
						body: expect.objectContaining({ objectID: 'doc-1' })
					})
				]
			});
		} finally {
			if (previousRemoteFlag === undefined) {
				delete process.env.PLAYWRIGHT_TARGET_REMOTE;
			} else {
				process.env.PLAYWRIGHT_TARGET_REMOTE = previousRemoteFlag;
			}
		}
	});

	it('does not re-submit API batch ingest when remote search readiness lags', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const previousRemoteFlag = process.env.PLAYWRIGHT_TARGET_REMOTE;
		process.env.PLAYWRIGHT_TARGET_REMOTE = '1';
		try {
			const indexName = 'remote-slow-search-readiness-index';
			const expectedHitText = 'Remote Slow Readiness Hit';
			const remoteApiOrigin = 'https://api.staging.flapjack.foo';
			let apiBatchAttempts = 0;
			let searchAttempts = 0;
			let directFlapjackIngestAttempted = false;

			const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
				const requestUrl =
					typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
				const parsedUrl = new URL(requestUrl);
				const method = (init?.method ?? 'GET').toUpperCase();
				const path = parsedUrl.pathname;

				if (path === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`) {
					directFlapjackIngestAttempted = true;
					return jsonResponse({}, 200);
				}

				if (parsedUrl.origin !== remoteApiOrigin) {
					throw new Error(
						`Unexpected non-API origin in remote-target mode: ${parsedUrl.origin}${path}`
					);
				}

				if (method === 'POST' && path === '/admin/tenants/customer-1/indexes') {
					return jsonResponse({}, 200);
				}
				if (method === 'POST' && path === '/indexes') {
					return jsonResponse({ name: indexName }, 201);
				}
				if (method === 'GET' && path === `/indexes/${encodeURIComponent(indexName)}`) {
					return jsonResponse({ name: indexName }, 200);
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
					return jsonResponse({ key: 'remote-test-key' }, 200);
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/batch`) {
					apiBatchAttempts += 1;
					return jsonResponse({}, 200);
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
					searchAttempts += 1;
					return jsonResponse(
						{ hits: searchAttempts >= 125 ? [{ title: expectedHitText }] : [] },
						200
					);
				}
				throw new Error(`Unexpected request: ${method} ${parsedUrl.origin}${path}`);
			}) as typeof fetch;

			await expect(
				seedSearchableIndexForCustomer({
					apiUrl: remoteApiOrigin,
					adminKey: 'admin-key',
					customerId: 'customer-1',
					token: 'customer-token',
					name: indexName,
					region: 'us-east-1',
					flapjackUrl: remoteApiOrigin,
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

			expect(directFlapjackIngestAttempted).toBe(false);
			// No re-submit: lagging remote search readiness must not retry the ingest.
			expect(apiBatchAttempts).toBe(1);
			// Convergence lower bound: search polling must continue through the lag window.
			expect(searchAttempts).toBeGreaterThanOrEqual(125);
		} finally {
			if (previousRemoteFlag === undefined) {
				delete process.env.PLAYWRIGHT_TARGET_REMOTE;
			} else {
				process.env.PLAYWRIGHT_TARGET_REMOTE = previousRemoteFlag;
			}
		}
	});

	it('retries remote API batch ingest while the endpoint is warming', async () => {
		const observedDelays: number[] = [];
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler,
			timeout?: number
		): ReturnType<typeof setTimeout> => {
			observedDelays.push(timeout ?? 0);
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const previousRemoteFlag = process.env.PLAYWRIGHT_TARGET_REMOTE;
		process.env.PLAYWRIGHT_TARGET_REMOTE = '1';
		try {
			const indexName = 'remote-api-batch-warmup-index';
			const expectedHitText = 'Remote API Batch Warmup Hit';
			const remoteApiOrigin = 'https://api.staging.flapjack.foo';
			let apiBatchAttempts = 0;
			let keyCreateAttempts = 0;

			const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
				const requestUrl =
					typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
				const parsedUrl = new URL(requestUrl);
				const method = (init?.method ?? 'GET').toUpperCase();
				const path = parsedUrl.pathname;

				if (parsedUrl.origin !== remoteApiOrigin) {
					throw new Error(
						`Unexpected non-API origin in remote-target mode: ${parsedUrl.origin}${path}`
					);
				}

				if (method === 'POST' && path === '/admin/tenants/customer-1/indexes') {
					return jsonResponse({}, 200);
				}
				if (method === 'POST' && path === '/indexes') {
					return jsonResponse({ name: indexName }, 201);
				}
				if (method === 'GET' && path === `/indexes/${encodeURIComponent(indexName)}`) {
					return jsonResponse({ name: indexName }, 200);
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
					keyCreateAttempts += 1;
					throw new Error('remote API-batch seed must not create an unused index key');
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/batch`) {
					apiBatchAttempts += 1;
					if (apiBatchAttempts <= 150) {
						return textResponse('{"error":"endpoint not ready yet"}', 503);
					}
					return jsonResponse({}, 200);
				}
				if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
					return jsonResponse(
						{ hits: apiBatchAttempts > 150 ? [{ title: expectedHitText }] : [] },
						200
					);
				}
				throw new Error(`Unexpected request: ${method} ${parsedUrl.origin}${path}`);
			}) as typeof fetch;

			await expect(
				seedSearchableIndexForCustomer({
					apiUrl: remoteApiOrigin,
					adminKey: 'admin-key',
					customerId: 'customer-1',
					token: 'customer-token',
					name: indexName,
					region: 'us-east-1',
					flapjackUrl: remoteApiOrigin,
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
			// Branch not taken: remote API-batch seeding must not create an unused index key.
			expect(keyCreateAttempts).toBe(0);
			expect(Math.max(...observedDelays)).toBeLessThanOrEqual(500);
		} finally {
			if (previousRemoteFlag === undefined) {
				delete process.env.PLAYWRIGHT_TARGET_REMOTE;
			} else {
				process.env.PLAYWRIGHT_TARGET_REMOTE = previousRemoteFlag;
			}
		}
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
		let adminCreated = false;

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
				adminCreated = true;
				return textResponse('', 200);
			}

			if (method === 'GET' && pathname === `/indexes/${encodeURIComponent(indexName)}`) {
				if (!adminCreated) {
					throw new Error('Index readiness check reached before admin creation recovered');
				}
				return jsonResponse({ name: indexName }, 200);
			}

			if (method === 'POST' && pathname === `/indexes/${encodeURIComponent(indexName)}/keys`) {
				if (!adminCreated) {
					throw new Error('Index key creation reached before admin creation recovered');
				}
				return jsonResponse({ key: 'test-key' }, 200);
			}

			if (
				method === 'POST' &&
				pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`
			) {
				if (!adminCreated) {
					throw new Error('Batch ingest reached before admin creation recovered');
				}
				return textResponse('', 200);
			}

			if (method === 'POST' && pathname === `/indexes/${encodeURIComponent(indexName)}/search`) {
				if (!adminCreated) {
					throw new Error('Search reached before admin creation recovered');
				}
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
	});
});

describe('createSeedSearchableIndexFactory', () => {
	afterEach(() => {
		vi.restoreAllMocks();
	});

	it('waits for metrics-ready document counts after search readiness when requested', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const indexName = 'factory-metrics-ready-index';
		const documents = Array.from({ length: 12 }, (_, index) => ({
			objectID: `metrics-doc-${index + 1}`,
			title: index === 0 ? 'Metrics Ready Document' : `Metrics Ready Extra ${index + 1}`
		}));
		const observedSteps: string[] = [];
		let metricsAttempts = 0;
		let batchIngested = false;
		let searchReady = false;
		const waitForSeededIndex = vi.fn(async () => undefined);
		const getCustomerId = vi.fn(async () => 'customer-1');
		const adminApiCall = vi.fn(async () => textResponse('', 200));
		const apiCall = vi.fn(async (method: string, path: string) => {
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
				return jsonResponse({ key: 'test-key' }, 200);
			}
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
				observedSteps.push('search');
				searchReady = batchIngested;
				return jsonResponse(
					{
						hits: searchReady ? [{ title: 'Rust Programming Language Metrics Ready Document' }] : []
					},
					200
				);
			}
			if (method === 'GET' && path === `/indexes/${encodeURIComponent(indexName)}/metrics`) {
				observedSteps.push('metrics');
				expect(searchReady).toBe(true);
				metricsAttempts += 1;
				return jsonResponse(
					{
						index: indexName,
						documents_count: metricsAttempts >= 3 ? documents.length : 0,
						storage_bytes: 1024,
						search_requests_total: 0,
						write_operations_total: documents.length,
						fetched_at: '2026-07-10T00:00:00Z'
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
			if (pathname.startsWith('/1/indexes/') && pathname.endsWith(`_${indexName}/batch`)) {
				batchIngested = true;
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

		await expect(
			seedSearchableIndex(indexName, {
				query: 'Metrics Ready',
				expectedHitText: 'Metrics Ready Document',
				documents,
				metricsReady: { expectedDocumentCount: documents.length }
			})
		).resolves.toEqual({
			name: indexName,
			query: 'Metrics Ready',
			expectedHitText: 'Metrics Ready Document',
			metrics: {
				documentsCount: documents.length,
				expectedDocumentCount: documents.length
			}
		});
		expect(observedSteps[0]).toBe('search');
		expect(metricsAttempts).toBe(3);
	});

	it('fails loudly when requested metrics-ready document counts never converge', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const indexName = 'factory-metrics-timeout-index';
		const documents = Array.from({ length: 12 }, (_, index) => ({
			objectID: `timeout-doc-${index + 1}`,
			title: index === 0 ? 'Timeout Metrics Document' : `Timeout Extra ${index + 1}`
		}));
		const waitForSeededIndex = vi.fn(async () => undefined);
		const getCustomerId = vi.fn(async () => 'customer-1');
		const adminApiCall = vi.fn(async () => textResponse('', 200));
		const apiCall = vi.fn(async (method: string, path: string) => {
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
				return jsonResponse({ key: 'test-key' }, 200);
			}
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
				return jsonResponse(
					{ hits: [{ title: 'Rust Programming Language Timeout Metrics Document' }] },
					200
				);
			}
			if (method === 'GET' && path === `/indexes/${encodeURIComponent(indexName)}/metrics`) {
				return jsonResponse(
					{
						index: indexName,
						documents_count: 11,
						storage_bytes: 1024,
						search_requests_total: 0,
						write_operations_total: 11,
						fetched_at: '2026-07-10T00:00:00Z'
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
			if (pathname.startsWith('/1/indexes/') && pathname.endsWith(`_${indexName}/batch`)) {
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

		await expect(
			seedSearchableIndex(indexName, {
				query: 'Timeout Metrics',
				expectedHitText: 'Timeout Metrics Document',
				documents,
				metricsReady: {
					expectedDocumentCount: documents.length,
					maxAttempts: 3,
					pollIntervalMs: 1
				}
			})
		).rejects.toThrow(
			`seedSearchableIndex: metrics document count for "${indexName}" did not reach 12`
		);
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
		// No re-submit: quota-limited API-batch fallback should be attempted exactly once.
		expect(apiBatchAttempts).toBe(1);
		// Convergence lower bound: quota fallback must keep polling for searchable results.
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
		let adminCreated = false;
		const waitForSeededIndex = vi.fn(async () => {
			if (!adminCreated) {
				throw new Error('Readiness wait reached before admin creation recovered');
			}
		});
		const getCustomerId = vi.fn(async () => 'customer-1');
		const adminApiCall = vi.fn(async () => {
			adminCreateAttempts += 1;
			if (adminCreateAttempts <= 3) {
				return new Response('{"error":"backend temporarily unavailable"}', {
					status: 503,
					headers: { 'retry-after': '1' }
				});
			}
			adminCreated = true;
			return textResponse('', 200);
		});
		const apiCall = vi.fn(async (method: string, path: string) => {
			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/keys`) {
				if (!adminCreated) {
					throw new Error('Index key creation reached before admin creation recovered');
				}
				return jsonResponse({ key: 'test-key' }, 200);
			}

			if (method === 'POST' && path === `/indexes/${encodeURIComponent(indexName)}/search`) {
				if (!adminCreated) {
					throw new Error('Search reached before admin creation recovered');
				}
				return jsonResponse({ hits: [{ title: 'Rust Programming Language' }] }, 200);
			}

			throw new Error(`Unexpected request: ${method} ${path}`);
		});
		vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: RequestInfo | URL) => {
			const requestUrl =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			const { pathname } = new URL(requestUrl);
			if (pathname === `/1/indexes/customer1_${encodeURIComponent(indexName)}/batch`) {
				if (!adminCreated) {
					throw new Error('Batch ingest reached before admin creation recovered');
				}
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
		expect(waitForSeededIndex).toHaveBeenCalledWith(indexName);
	});
});
