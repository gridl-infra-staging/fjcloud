import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
	adminReactivateCustomerById,
	createRegisteredUser,
	fetchEstimatedBillForToken,
	formatFixtureSetupFailure,
	loginAsUser,
	seedMultiUserScenarioWithCreateUser
} from '../../tests/fixtures/fixtures';
import {
	createSeedSearchableIndexFactory,
	seedIndexForCustomerViaAdmin,
	seedSearchableIndexForCustomer
} from '../../tests/fixtures/searchable-index';
import { DEFAULT_FLAPJACK_URL } from '../../playwright.config.contract';

type MockJsonBody = Record<string, unknown>;

function makeJsonResponse(status: number, body: MockJsonBody): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

describe('e2e fixture user helpers', () => {
	beforeEach(() => {
		vi.restoreAllMocks();
	});

	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	it('createRegisteredUser posts to /auth/register and tracks cleanup', async () => {
		const fetchMock = vi.fn().mockResolvedValue(
			makeJsonResponse(201, {
				customer_id: 'cust-123',
				token: 'tok-abc'
			})
		);
		const trackedCustomerIds: string[] = [];

		const created = await createRegisteredUser({
			apiUrl: 'http://localhost:3001',
			email: 'user@example.com',
			password: 'TestPassword123!',
			name: 'Fixture User',
			fetchImpl: fetchMock as unknown as typeof fetch,
			trackCustomerForCleanup: (customerId) => trackedCustomerIds.push(customerId)
		});

		expect(created).toEqual({
			customerId: 'cust-123',
			token: 'tok-abc',
			email: 'user@example.com',
			password: 'TestPassword123!'
		});
		expect(trackedCustomerIds).toEqual(['cust-123']);
		expect(fetchMock).toHaveBeenCalledWith('http://localhost:3001/auth/register', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				name: 'Fixture User',
				email: 'user@example.com',
				password: 'TestPassword123!'
			})
		});
	});

	it('createRegisteredUser fails fast when required contract inputs are blank', async () => {
		const fetchMock = vi.fn();

		await expect(
			createRegisteredUser({
				apiUrl: 'http://localhost:3001',
				email: '   ',
				password: '',
				fetchImpl: fetchMock as unknown as typeof fetch,
				trackCustomerForCleanup: () => {}
			})
		).rejects.toThrow('createRegisteredUser requires non-empty email and password');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('createRegisteredUser preserves non-blank passwords exactly as provided', async () => {
		const fetchMock = vi.fn().mockResolvedValue(
			makeJsonResponse(201, {
				customer_id: 'cust-456',
				token: 'tok-def'
			})
		);
		const passwordWithWhitespace = '  Pass phrase  ';

		const created = await createRegisteredUser({
			apiUrl: 'http://localhost:3001',
			email: 'user@example.com',
			password: passwordWithWhitespace,
			fetchImpl: fetchMock as unknown as typeof fetch,
			trackCustomerForCleanup: () => {}
		});

		expect(created.password).toBe(passwordWithWhitespace);
		expect(fetchMock).toHaveBeenCalledWith('http://localhost:3001/auth/register', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				name: 'E2E Fixture user@example.com',
				email: 'user@example.com',
				password: passwordWithWhitespace
			})
		});
	});

	it('createRegisteredUser retries 429 responses before succeeding', async () => {
		vi.useFakeTimers();
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ error: 'too many requests' }), { status: 429 })
			)
			.mockResolvedValueOnce(
				makeJsonResponse(201, {
					customer_id: 'cust-789',
					token: 'tok-retry'
				})
			);

		const promise = createRegisteredUser({
			apiUrl: 'http://localhost:3001',
			email: 'retry@example.com',
			password: 'TestPassword123!',
			fetchImpl: fetchMock as unknown as typeof fetch,
			trackCustomerForCleanup: () => {}
		});

		await vi.runAllTimersAsync();

		await expect(promise).resolves.toEqual({
			customerId: 'cust-789',
			token: 'tok-retry',
			email: 'retry@example.com',
			password: 'TestPassword123!'
		});
		expect(fetchMock).toHaveBeenCalledTimes(2);
	});

	it('loginAsUser posts to /auth/login and returns a fresh token', async () => {
		const fetchMock = vi.fn().mockResolvedValue(
			makeJsonResponse(200, {
				customer_id: 'cust-123',
				token: 'login-token'
			})
		);

		const token = await loginAsUser({
			apiUrl: 'http://localhost:3001',
			email: 'user@example.com',
			password: 'TestPassword123!',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(token).toBe('login-token');
		expect(fetchMock).toHaveBeenCalledWith('http://localhost:3001/auth/login', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				email: 'user@example.com',
				password: 'TestPassword123!'
			})
		});
	});

	it('loginAsUser retries 429 responses before succeeding', async () => {
		vi.useFakeTimers();
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ error: 'too many requests' }), { status: 429 })
			)
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					customer_id: 'cust-123',
					token: 'retry-login-token'
				})
			);

		const promise = loginAsUser({
			apiUrl: 'http://localhost:3001',
			email: 'user@example.com',
			password: 'TestPassword123!',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		await vi.runAllTimersAsync();

		await expect(promise).resolves.toBe('retry-login-token');
		expect(fetchMock).toHaveBeenCalledTimes(2);
	});

	it('seedMultiUserScenarioWithCreateUser creates two unique users', async () => {
		const createUser = vi
			.fn()
			.mockResolvedValueOnce({
				customerId: 'cust-1',
				token: 'tok-1',
				email: 'primary@example.com',
				password: 'TestPassword123!'
			})
			.mockResolvedValueOnce({
				customerId: 'cust-2',
				token: 'tok-2',
				email: 'secondary@example.com',
				password: 'TestPassword123!'
			});

		const seeded = await seedMultiUserScenarioWithCreateUser({
			createUser,
			password: 'TestPassword123!',
			uniqueId: 'fixed-seed'
		});

		expect(createUser).toHaveBeenCalledTimes(2);
		const firstEmail = createUser.mock.calls[0]?.[0];
		const secondEmail = createUser.mock.calls[1]?.[0];
		expect(firstEmail).not.toBe(secondEmail);
		expect(firstEmail).toContain('fixed-seed');
		expect(secondEmail).toContain('fixed-seed');
		expect(seeded.primaryUser.customerId).toBe('cust-1');
		expect(seeded.secondaryUser.customerId).toBe('cust-2');
	});

	it('adminReactivateCustomerById calls POST /admin/customers/:id/reactivate', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(makeJsonResponse(200, { message: 'customer reactivated' }));

		await adminReactivateCustomerById({
			apiUrl: 'http://localhost:3001',
			customerId: 'cust-123',
			adminKey: 'admin-key',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(fetchMock).toHaveBeenCalledWith(
			'http://localhost:3001/admin/customers/cust-123/reactivate',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					'x-admin-key': 'admin-key'
				},
				body: undefined
			}
		);
	});

	it('adminReactivateCustomerById fails fast when E2E_ADMIN_KEY is missing', async () => {
		const fetchMock = vi.fn();

		await expect(
			adminReactivateCustomerById({
				apiUrl: 'http://localhost:3001',
				customerId: 'cust-123',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('E2E_ADMIN_KEY must be set for admin API calls');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('adminReactivateCustomerById fails fast when customerId is blank', async () => {
		const fetchMock = vi.fn();

		await expect(
			adminReactivateCustomerById({
				apiUrl: 'http://localhost:3001',
				customerId: '   ',
				adminKey: 'admin-key',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('adminReactivateCustomerById requires a non-empty customerId');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('fetchEstimatedBillForToken includes month query when provided', async () => {
		const fetchMock = vi.fn().mockResolvedValue(
			makeJsonResponse(200, {
				month: '2026-03',
				subtotal_cents: 1800,
				total_cents: 1800,
				minimum_applied: false,
				line_items: []
			})
		);

		const estimate = await fetchEstimatedBillForToken({
			apiUrl: 'http://localhost:3001',
			token: 'tok-abc',
			month: '2026-03',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(estimate?.month).toBe('2026-03');
		expect(fetchMock).toHaveBeenCalledWith('http://localhost:3001/billing/estimate?month=2026-03', {
			method: 'GET',
			headers: { Authorization: 'Bearer tok-abc' }
		});
	});

	it('fetchEstimatedBillForToken returns null for 404 (no estimate data)', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(
				new Response(JSON.stringify({ error: 'no active rate card' }), { status: 404 })
			);

		const estimate = await fetchEstimatedBillForToken({
			apiUrl: 'http://localhost:3001',
			token: 'tok-abc',
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(estimate).toBeNull();
		expect(fetchMock).toHaveBeenCalledWith('http://localhost:3001/billing/estimate', {
			method: 'GET',
			headers: { Authorization: 'Bearer tok-abc' }
		});
	});

	it('fetchEstimatedBillForToken throws on auth errors (401/403)', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 }));

		await expect(
			fetchEstimatedBillForToken({
				apiUrl: 'http://localhost:3001',
				token: 'expired-tok',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('/billing/estimate failed: 401');
	});

	it('fetchEstimatedBillForToken throws on server errors (5xx)', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(
				new Response(JSON.stringify({ error: 'internal error' }), { status: 500 })
			);

		await expect(
			fetchEstimatedBillForToken({
				apiUrl: 'http://localhost:3001',
				token: 'tok-abc',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('/billing/estimate failed: 500');
	});

	it('seedIndexForCustomerViaAdmin retries transient create failures before polling readiness', async () => {
		vi.useFakeTimers();

		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(new Response('temporary failure', { status: 500 }))
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'shared-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { name: 'shared-index' }));

		const seedPromise = seedIndexForCustomerViaAdmin({
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key',
			customerId: 'cust-123',
			token: 'tok-abc',
			name: 'shared-index',
			region: 'us-east-1',
			fetchImpl: fetchMock as unknown as typeof fetch
		});
		await vi.runAllTimersAsync();
		await seedPromise;

		expect(fetchMock).toHaveBeenNthCalledWith(
			1,
			'http://localhost:3001/admin/tenants/cust-123/indexes',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					'x-admin-key': 'admin-key'
				},
				body: JSON.stringify({
					name: 'shared-index',
					region: 'us-east-1'
				})
			}
		);
		expect(fetchMock).toHaveBeenNthCalledWith(
			2,
			'http://localhost:3001/admin/tenants/cust-123/indexes',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					'x-admin-key': 'admin-key'
				},
				body: JSON.stringify({
					name: 'shared-index',
					region: 'us-east-1'
				})
			}
		);
		expect(fetchMock).toHaveBeenNthCalledWith(3, 'http://localhost:3001/indexes/shared-index', {
			method: 'GET',
			headers: {
				'Content-Type': 'application/json',
				Authorization: 'Bearer tok-abc'
			},
			body: undefined
		});
	});

	it('seedIndexForCustomerViaAdmin fails fast when required auth contract is missing', async () => {
		const fetchMock = vi.fn();

		await expect(
			seedIndexForCustomerViaAdmin({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: 'cust-123',
				token: '',
				name: 'shared-index',
				region: 'us-east-1',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('seedIndexForCustomerViaAdmin requires a non-empty token');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('seedIndexForCustomerViaAdmin fails fast when customerId is blank', async () => {
		const fetchMock = vi.fn();

		await expect(
			seedIndexForCustomerViaAdmin({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: '   ',
				token: 'tok-abc',
				name: 'shared-index',
				region: 'us-east-1',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('seedIndexForCustomerViaAdmin requires a non-empty customerId');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('seedIndexForCustomerViaAdmin fails fast when index name is blank', async () => {
		const fetchMock = vi.fn();

		await expect(
			seedIndexForCustomerViaAdmin({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: 'cust-123',
				token: 'tok-abc',
				name: '   ',
				region: 'us-east-1',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('seedIndexForCustomerViaAdmin requires a non-empty index name');

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('seedIndexForCustomerViaAdmin accepts a duplicate-name conflict after a retried create', async () => {
		vi.useFakeTimers();

		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(new Response('temporary failure', { status: 500 }))
			.mockResolvedValueOnce(new Response('duplicate name', { status: 409 }))
			.mockResolvedValueOnce(makeJsonResponse(200, { name: 'shared-index' }));

		const seedPromise = seedIndexForCustomerViaAdmin({
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key',
			customerId: 'cust-123',
			token: 'tok-abc',
			name: 'shared-index',
			region: 'us-east-1',
			fetchImpl: fetchMock as unknown as typeof fetch
		});
		await vi.runAllTimersAsync();
		await seedPromise;

		expect(fetchMock).toHaveBeenCalledTimes(3);
	});

	it('seedSearchableIndexForCustomer provisions searchable documents for an explicit customer', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { key: 'search-key' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { taskID: 1 }))
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					hits: [{ title: 'Tenant A Document' }]
				})
			);

		const seeded = await seedSearchableIndexForCustomer({
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key',
			customerId: 'cust-123',
			token: 'tok-abc',
			name: 'search-index',
			region: 'us-east-1',
			flapjackUrl: 'http://localhost:7700',
			query: 'Tenant',
			expectedHitText: 'Tenant A Document',
			documents: [{ objectID: 'doc-1', title: 'Tenant A Document' }],
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(seeded).toEqual({
			name: 'search-index',
			query: 'Tenant',
			expectedHitText: 'Tenant A Document'
		});
		expect(fetchMock).toHaveBeenNthCalledWith(
			4,
			'http://localhost:7700/1/indexes/cust123_search-index/batch',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					'X-Algolia-API-Key': 'search-key',
					'X-Algolia-Application-Id': 'flapjack'
				},
				body: JSON.stringify({
					requests: [
						{ action: 'addObject', body: { objectID: 'doc-1', title: 'Tenant A Document' } }
					]
				})
			}
		);
		expect(fetchMock).toHaveBeenNthCalledWith(
			5,
			'http://localhost:3001/indexes/search-index/search',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer tok-abc'
				},
				body: JSON.stringify({
					query: 'Tenant'
				})
			}
		);
	});

	it('seedSearchableIndexForCustomer uses contract DEFAULT_FLAPJACK_URL when flapjackUrl is omitted', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { key: 'search-key' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { taskID: 1 }))
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					hits: [{ title: 'Rust Programming Language' }]
				})
			);

		await seedSearchableIndexForCustomer({
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key',
			customerId: 'cust-123',
			token: 'tok-abc',
			name: 'search-index',
			region: 'us-east-1',
			// flapjackUrl intentionally omitted — should use DEFAULT_FLAPJACK_URL
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		// The ingest call (4th) should use the contract default flapjack URL
		expect(fetchMock).toHaveBeenNthCalledWith(
			4,
			`${DEFAULT_FLAPJACK_URL}/1/indexes/cust123_search-index/batch`,
			expect.objectContaining({ method: 'POST' })
		);
	});

	it('createSeedSearchableIndexFactory uses injected flapjackUrl from deps', async () => {
		// Stub global fetch for ingest call inside the factory
		const globalFetchMock = vi.fn().mockResolvedValue(makeJsonResponse(200, { taskID: 1 }));
		vi.stubGlobal('fetch', globalFetchMock);

		const apiCallMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(200, { key: 'search-key' }))
			.mockResolvedValueOnce(
				makeJsonResponse(200, { hits: [{ title: 'Rust Programming Language' }] })
			);
		const adminApiCallMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'factory-index' }));
		const getCustomerIdMock = vi.fn().mockResolvedValue('cust-factory');
		const waitForSeededIndexMock = vi.fn().mockResolvedValue(undefined);

		const seedFn = createSeedSearchableIndexFactory({
			testRegion: 'us-east-1',
			apiCall: apiCallMock,
			adminApiCall: adminApiCallMock,
			getCustomerId: getCustomerIdMock,
			waitForSeededIndex: waitForSeededIndexMock,
			flapjackUrl: 'http://127.0.0.1:9900'
		});

		await seedFn('factory-index');

		// The admin create call should pass the injected flapjackUrl
		expect(adminApiCallMock).toHaveBeenCalledWith('POST', '/admin/tenants/cust-factory/indexes', {
			name: 'factory-index',
			region: 'us-east-1',
			flapjack_url: 'http://127.0.0.1:9900'
		});
		// The ingest call (via global fetch) should use the injected flapjackUrl
		expect(globalFetchMock).toHaveBeenCalledWith(
			'http://127.0.0.1:9900/1/indexes/custfactory_factory-index/batch',
			expect.objectContaining({ method: 'POST' })
		);
	});

	it('seedSearchableIndexForCustomer rejects non-loopback flapjackUrl overrides', async () => {
		const fetchMock = vi.fn();

		await expect(
			seedSearchableIndexForCustomer({
				apiUrl: 'http://localhost:3001',
				adminKey: 'admin-key',
				customerId: 'cust-123',
				token: 'tok-abc',
				name: 'search-index',
				region: 'us-east-1',
				flapjackUrl: 'https://flapjack.example.com',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow(
			'FLAPJACK_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('createSeedSearchableIndexFactory falls back to contract DEFAULT_FLAPJACK_URL when flapjackUrl omitted', async () => {
		// Stub global fetch for ingest call inside the factory
		const globalFetchMock = vi.fn().mockResolvedValue(makeJsonResponse(200, { taskID: 1 }));
		vi.stubGlobal('fetch', globalFetchMock);

		const apiCallMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(200, { key: 'search-key' }))
			.mockResolvedValueOnce(
				makeJsonResponse(200, { hits: [{ title: 'Rust Programming Language' }] })
			);
		const adminApiCallMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'factory-index' }));
		const getCustomerIdMock = vi.fn().mockResolvedValue('cust-factory');
		const waitForSeededIndexMock = vi.fn().mockResolvedValue(undefined);

		const seedFn = createSeedSearchableIndexFactory({
			testRegion: 'us-east-1',
			apiCall: apiCallMock,
			adminApiCall: adminApiCallMock,
			getCustomerId: getCustomerIdMock,
			waitForSeededIndex: waitForSeededIndexMock
		});

		await seedFn('factory-index');

		// Should use DEFAULT_FLAPJACK_URL from contract
		expect(adminApiCallMock).toHaveBeenCalledWith('POST', '/admin/tenants/cust-factory/indexes', {
			name: 'factory-index',
			region: 'us-east-1',
			flapjack_url: DEFAULT_FLAPJACK_URL
		});
	});

	it('createSeedSearchableIndexFactory rejects non-loopback flapjackUrl overrides', async () => {
		const globalFetchMock = vi.fn();
		vi.stubGlobal('fetch', globalFetchMock);
		const apiCallMock = vi.fn();
		const adminApiCallMock = vi.fn();

		const seedFn = createSeedSearchableIndexFactory({
			testRegion: 'us-east-1',
			apiCall: apiCallMock,
			adminApiCall: adminApiCallMock,
			getCustomerId: vi.fn().mockResolvedValue('cust-factory'),
			waitForSeededIndex: vi.fn().mockResolvedValue(undefined),
			flapjackUrl: 'https://flapjack.example.com'
		});

		await expect(seedFn('factory-index')).rejects.toThrow(
			'FLAPJACK_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);
		expect(adminApiCallMock).not.toHaveBeenCalled();
		expect(globalFetchMock).not.toHaveBeenCalled();
	});

	it('loginAsUser throws on auth failure (401)', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(
				new Response(JSON.stringify({ error: 'invalid credentials' }), { status: 401 })
			);

		await expect(
			loginAsUser({
				apiUrl: 'http://localhost:3001',
				email: 'user@example.com',
				password: 'wrong',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow('loginAs failed: 401');
	});

	it('loginAsUser fails after exhausting 429 retries', async () => {
		vi.useFakeTimers();
		const fetchMock = vi
			.fn()
			.mockResolvedValue(
				new Response(JSON.stringify({ error: 'too many requests' }), { status: 429 })
			);

		const promise = loginAsUser({
			apiUrl: 'http://localhost:3001',
			email: 'user@example.com',
			password: 'TestPassword123!',
			fetchImpl: fetchMock as unknown as typeof fetch
		});
		const rejection = expect(promise).rejects.toThrow(
			'loginAs failed: exhausted retries after 429 rate limiting'
		);

		await vi.runAllTimersAsync();
		await rejection;
		expect(fetchMock).toHaveBeenCalledTimes(10);
	});

	it('loginAsUser rejects non-loopback apiUrl', async () => {
		const fetchMock = vi.fn();

		await expect(
			loginAsUser({
				apiUrl: 'https://api.example.com',
				email: 'user@example.com',
				password: 'TestPassword123!',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow(
			'API_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('createRegisteredUser rejects non-loopback apiUrl', async () => {
		const fetchMock = vi.fn();

		await expect(
			createRegisteredUser({
				apiUrl: 'https://api.example.com',
				email: 'user@example.com',
				password: 'TestPassword123!',
				fetchImpl: fetchMock as unknown as typeof fetch,
				trackCustomerForCleanup: () => {}
			})
		).rejects.toThrow(
			'API_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('createRegisteredUser throws on non-ok API response', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValue(new Response(JSON.stringify({ error: 'email taken' }), { status: 409 }));

		await expect(
			createRegisteredUser({
				apiUrl: 'http://localhost:3001',
				email: 'taken@example.com',
				password: 'TestPassword123!',
				fetchImpl: fetchMock as unknown as typeof fetch,
				trackCustomerForCleanup: () => {}
			})
		).rejects.toThrow('createUser failed: 409');
	});

	it('createRegisteredUser fails after exhausting 429 retries', async () => {
		vi.useFakeTimers();
		const fetchMock = vi
			.fn()
			.mockResolvedValue(
				new Response(JSON.stringify({ error: 'too many requests' }), { status: 429 })
			);

		const promise = createRegisteredUser({
			apiUrl: 'http://localhost:3001',
			email: 'retry-limit@example.com',
			password: 'TestPassword123!',
			fetchImpl: fetchMock as unknown as typeof fetch,
			trackCustomerForCleanup: () => {}
		});
		const rejection = expect(promise).rejects.toThrow(
			'createUser failed: exhausted retries after 429 rate limiting'
		);

		await vi.runAllTimersAsync();
		await rejection;
		expect(fetchMock).toHaveBeenCalledTimes(10);
	});

	it('fetchEstimatedBillForToken rejects non-loopback apiUrl', async () => {
		const fetchMock = vi.fn();

		await expect(
			fetchEstimatedBillForToken({
				apiUrl: 'https://billing.example.com',
				token: 'tok-abc',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow(
			'API_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('adminReactivateCustomerById rejects non-loopback apiUrl', async () => {
		const fetchMock = vi.fn();

		await expect(
			adminReactivateCustomerById({
				apiUrl: 'https://admin.example.com',
				customerId: 'cust-123',
				adminKey: 'admin-key',
				fetchImpl: fetchMock as unknown as typeof fetch
			})
		).rejects.toThrow(
			'API_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs'
		);

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('seedSearchableIndexForCustomer reuses normalized token and index name after the guard step', async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(makeJsonResponse(201, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { name: 'search-index' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { key: 'search-key' }))
			.mockResolvedValueOnce(makeJsonResponse(200, { taskID: 1 }))
			.mockResolvedValueOnce(
				makeJsonResponse(200, {
					hits: [{ title: 'Tenant A Document' }]
				})
			);

		const seeded = await seedSearchableIndexForCustomer({
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key',
			customerId: ' cust-123 ',
			token: ' tok-abc ',
			name: ' search-index ',
			region: 'us-east-1',
			flapjackUrl: 'http://localhost:7700',
			query: 'Tenant',
			expectedHitText: 'Tenant A Document',
			documents: [{ objectID: 'doc-1', title: 'Tenant A Document' }],
			fetchImpl: fetchMock as unknown as typeof fetch
		});

		expect(seeded.name).toBe('search-index');
		expect(fetchMock).toHaveBeenNthCalledWith(
			3,
			'http://localhost:3001/indexes/search-index/keys',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer tok-abc'
				},
				body: JSON.stringify({
					description: 'e2e-search-search-index',
					acl: ['search', 'addObject']
				})
			}
		);
		expect(fetchMock).toHaveBeenNthCalledWith(
			5,
			'http://localhost:3001/indexes/search-index/search',
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer tok-abc'
				},
				body: JSON.stringify({
					query: 'Tenant'
				})
			}
		);
	});

	it('formatFixtureSetupFailure reports api URL and masked admin-key fingerprint only', () => {
		const fullAdminKey = 'abcd-secret-super-long-key';
		const failureMessage = formatFixtureSetupFailure({
			setupName: 'customer auth setup',
			expectedPath: '/dashboard',
			currentPath: '/login',
			apiUrl: 'http://localhost:3001',
			adminKey: fullAdminKey,
			bootstrapCommand: 'scripts/bootstrap-env-local.sh',
			alertText: 'Invalid credentials'
		});

		expect(failureMessage).toContain('API URL: http://localhost:3001');
		// Per the 25beb7d7 "matt: posthoc security" tightening, the fingerprint
		// no longer leaks any prefix chars of the admin key — only presence
		// and length.
		expect(failureMessage).toContain('Admin key fingerprint: (present, len=26)');
		expect(failureMessage).not.toContain(fullAdminKey);
		expect(failureMessage).not.toContain('secret-super-long-key');
		expect(failureMessage).not.toContain('abcd');
		expect(failureMessage).toContain('scripts/bootstrap-env-local.sh');
		expect(failureMessage).toContain('scripts/api-dev.sh');
	});

	it('formatFixtureSetupFailure includes response status and URL without exposing full admin key', () => {
		const failureMessage = formatFixtureSetupFailure({
			setupName: 'admin auth setup',
			expectedPath: '/admin/fleet',
			currentPath: '/admin/login',
			apiUrl: 'http://localhost:3001',
			adminKey: 'admin-key-12345',
			bootstrapCommand: 'scripts/bootstrap-env-local.sh',
			responseStatus: 401,
			responseUrl: 'http://localhost:3001/admin/login'
		});

		expect(failureMessage).toContain(
			'Login response: status 401 at http://localhost:3001/admin/login'
		);
		// Privacy-safe fingerprint format (post 25beb7d7): no prefix chars.
		expect(failureMessage).toContain('Admin key fingerprint: (present, len=15)');
		expect(failureMessage).not.toContain('admin-key-12345');
		expect(failureMessage).not.toContain('Admin key fingerprint: admi');
		expect(failureMessage).toContain('scripts/bootstrap-env-local.sh');
		expect(failureMessage).toContain('scripts/api-dev.sh');
		expect(failureMessage).toContain('docs/runbooks/local-dev.md');
	});
});
