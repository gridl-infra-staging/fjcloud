import { describe, it, expect, beforeEach } from 'vitest';
import { ApiClient } from './client';
import type {
	AuthResponse,
	MessageResponse,
	UsageSummaryResponse,
	DailyUsageEntry,
	InvoiceListItem,
	SetupIntentResponse,
	PaymentMethod,
	CreateBillingPortalSessionRequest,
	CreateBillingPortalSessionResponse,
	EstimatedBillResponse,
	ApiKeyListItem,
	CreateApiKeyResponse,
	CustomerProfileResponse
} from './types';
import { BASE_URL, mockFetch, createClient, createAuthenticatedClient } from './client.test.shared';

describe('ApiClient', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createClient();
	});

	describe('constructor', () => {
		it('strips trailing slash from base URL', () => {
			const c = new ApiClient('http://localhost:3000/');
			// Verify by making a request and checking the URL
			const fetch = mockFetch(200, { message: 'ok' });
			c.setFetch(fetch);
			c.healthCheck();
			expect(fetch).toHaveBeenCalledWith('http://localhost:3000/health', expect.any(Object));
		});
	});

	it('does not expose the legacy getSubscription seam', () => {
		expect('getSubscription' in client).toBe(false);
		expect((client as unknown as Record<string, unknown>).getSubscription).toBeUndefined();
	});

	describe('auth endpoints', () => {
		it('POST /auth/register sends correct body and returns AuthResponse', async () => {
			const expected: AuthResponse = { token: 'jwt-123', customer_id: 'uuid-1' };
			const fetch = mockFetch(201, expected);
			client.setFetch(fetch);

			const result = await client.register({
				name: 'Alice',
				email: 'alice@example.com',
				password: 'password123'
			});

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/auth/register`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ name: 'Alice', email: 'alice@example.com', password: 'password123' })
			});
			expect(result).toEqual(expected);
		});

		it('POST /auth/login sends correct body and returns AuthResponse', async () => {
			const expected: AuthResponse = { token: 'jwt-456', customer_id: 'uuid-2' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.login({ email: 'bob@example.com', password: 'pass1234' });

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/auth/login`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ email: 'bob@example.com', password: 'pass1234' })
			});
			expect(result).toEqual(expected);
		});

		it('POST /auth/verify-email sends token', async () => {
			const expected: MessageResponse = { message: 'email verified' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.verifyEmail({ token: 'verify-token-abc' });

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/auth/verify-email`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ token: 'verify-token-abc' })
			});
			expect(result).toEqual(expected);
		});

		it('POST /auth/forgot-password sends email', async () => {
			const expected: MessageResponse = { message: 'if an account exists...' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.forgotPassword({ email: 'carol@example.com' });

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/auth/forgot-password`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ email: 'carol@example.com' })
			});
			expect(result).toEqual(expected);
		});

		it('POST /auth/reset-password sends token and new password', async () => {
			const expected: MessageResponse = { message: 'password has been reset' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.resetPassword({
				token: 'reset-token-xyz',
				new_password: 'newpass123'
			});

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/auth/reset-password`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ token: 'reset-token-xyz', new_password: 'newpass123' })
			});
			expect(result).toEqual(expected);
		});
	});

	describe('authenticated endpoints', () => {
		beforeEach(() => {
			client = createAuthenticatedClient();
		});

		it('GET /usage includes auth header', async () => {
			const expected: UsageSummaryResponse = {
				month: '2026-02',
				total_search_requests: 100,
				total_write_operations: 50,
				avg_storage_gb: 1.5,
				avg_document_count: 10000,
				by_region: []
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getUsage();

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/usage`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
			expect(result).toEqual(expected);
		});

		it('GET /usage with month param appends query string', async () => {
			const fetch = mockFetch(200, {
				month: '2026-01',
				total_search_requests: 0,
				total_write_operations: 0,
				avg_storage_gb: 0,
				avg_document_count: 0,
				by_region: []
			});
			client.setFetch(fetch);

			await client.getUsage('2026-01');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/usage?month=2026-01`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
		});

		it('GET /usage/daily returns daily entries', async () => {
			const expected: DailyUsageEntry[] = [
				{
					date: '2026-02-01',
					region: 'us-east-1',
					search_requests: 1000,
					write_operations: 100,
					storage_gb: 1.0,
					document_count: 5000
				}
			];
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getUsageDaily();

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/usage/daily`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
			expect(result).toEqual(expected);
		});

		it('GET /usage/daily with month param appends query string', async () => {
			const fetch = mockFetch(200, []);
			client.setFetch(fetch);

			await client.getUsageDaily('2026-01');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/usage/daily?month=2026-01`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
		});

		it('GET /invoices returns list', async () => {
			const expected: InvoiceListItem[] = [
				{
					id: 'inv-1',
					period_start: '2026-01-01',
					period_end: '2026-01-31',
					subtotal_cents: 5000,
					total_cents: 5000,
					status: 'draft',
					minimum_applied: false,
					created_at: '2026-01-15T00:00:00Z'
				}
			];
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getInvoices();

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/invoices`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
			expect(result).toEqual(expected);
		});

		it('GET /invoices/:id returns detail', async () => {
			const fetch = mockFetch(200, { id: 'inv-1', customer_id: 'c-1', line_items: [] });
			client.setFetch(fetch);

			await client.getInvoice('inv-1');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/invoices/inv-1`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
		});

		it('GET /invoices/:id encodes untrusted invoice IDs before building the path', async () => {
			const fetch = mockFetch(200, { id: 'inv-1', customer_id: 'c-1', line_items: [] });
			client.setFetch(fetch);

			await client.getInvoice('../usage?month=2026-01');

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/invoices/..%2Fusage%3Fmonth%3D2026-01`,
				expect.any(Object)
			);
		});

		it('POST /billing/setup-intent returns client_secret', async () => {
			const expected: SetupIntentResponse = { client_secret: 'seti_secret_123' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.createSetupIntent();

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/billing/setup-intent`, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				},
				body: undefined
			});
			expect(result).toEqual(expected);
		});

		it('GET /billing/payment-methods returns list', async () => {
			const expected: PaymentMethod[] = [
				{
					id: 'pm_1',
					card_brand: 'visa',
					last4: '4242',
					exp_month: 12,
					exp_year: 2027,
					is_default: true
				}
			];
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getPaymentMethods();

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/billing/payment-methods`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
			expect(result).toEqual(expected);
		});

		it('DELETE /billing/payment-methods/:pm_id sends correct request', async () => {
			const fetch = mockFetch(204, {});
			client.setFetch(fetch);

			await client.deletePaymentMethod('pm_abc');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/billing/payment-methods/pm_abc`, {
				method: 'DELETE',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
		});

		it('DELETE /billing/payment-methods/:pm_id encodes untrusted payment method IDs', async () => {
			const fetch = mockFetch(204, {});
			client.setFetch(fetch);

			await client.deletePaymentMethod('../subscription');

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/billing/payment-methods/..%2Fsubscription`,
				expect.any(Object)
			);
		});

		it('POST /billing/payment-methods/:pm_id/default sends correct request', async () => {
			const fetch = mockFetch(204, {});
			client.setFetch(fetch);

			await client.setDefaultPaymentMethod('pm_xyz');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/billing/payment-methods/pm_xyz/default`, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				},
				body: undefined
			});
		});

		it('POST /billing/payment-methods/:pm_id/default encodes untrusted payment method IDs', async () => {
			const fetch = mockFetch(204, {});
			client.setFetch(fetch);

			await client.setDefaultPaymentMethod('../subscription');

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/billing/payment-methods/..%2Fsubscription/default`,
				expect.any(Object)
			);
		});

		it('POST /billing/portal sends server-owned return_url and returns portal_url', async () => {
			const requestBody: CreateBillingPortalSessionRequest = {
				return_url: 'https://app.example.com/dashboard/billing'
			};
			const expected: CreateBillingPortalSessionResponse = {
				portal_url: 'https://billing.stripe.com/session/test_123'
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.createBillingPortalSession(requestBody);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/billing/portal`, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				},
				body: JSON.stringify(requestBody)
			});
			expect(result).toEqual(expected);
		});

		it('GET /billing/estimate returns estimated bill', async () => {
			const expected: EstimatedBillResponse = {
				month: '2026-02',
				subtotal_cents: 5000,
				total_cents: 5000,
				line_items: [
					{
						description: 'Search requests',
						quantity: '10.0',
						unit: 'requests_1k',
						unit_price_cents: '50',
						amount_cents: 500,
						region: 'us-east-1'
					}
				],
				minimum_applied: false
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getEstimatedBill();

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/billing/estimate`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
			expect(result).toEqual(expected);
		});

		it('GET /billing/estimate with month param appends query string', async () => {
			const fetch = mockFetch(200, {
				month: '2026-01',
				subtotal_cents: 0,
				total_cents: 500,
				line_items: [],
				minimum_applied: true
			});
			client.setFetch(fetch);

			await client.getEstimatedBill('2026-01');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/billing/estimate?month=2026-01`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
		});

		it('DELETE /billing/payment-methods returns undefined for 204', async () => {
			const fetch = mockFetch(204, {});
			client.setFetch(fetch);

			const result = await client.deletePaymentMethod('pm_abc');

			expect(result).toBeUndefined();
		});

		it('POST /api-keys sends request body with management scopes and returns gridl_live_ key', async () => {
			const expected: CreateApiKeyResponse = {
				id: 'key-1',
				name: 'My Key',
				key: 'gridl_live_abc123def456abc123def456ab',
				key_prefix: 'gridl_live_abc12',
				scopes: ['indexes:read', 'indexes:write'],
				created_at: '2026-02-15T00:00:00Z'
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.createApiKey({
				name: 'My Key',
				scopes: ['indexes:read', 'indexes:write']
			});

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/api-keys`, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				},
				body: JSON.stringify({ name: 'My Key', scopes: ['indexes:read', 'indexes:write'] })
			});
			expect(result).toEqual(expected);
			expect(result.key).toMatch(/^gridl_live_/);
		});

		it('GET /api-keys returns list of keys with gridl_live_ prefix', async () => {
			const expected: ApiKeyListItem[] = [
				{
					id: 'key-1',
					name: 'My Key',
					key_prefix: 'gridl_live_abc12',
					scopes: ['search'],
					last_used_at: null,
					created_at: '2026-02-15T00:00:00Z'
				}
			];
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getApiKeys();

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/api-keys`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
			expect(result).toEqual(expected);
			expect(result[0].key_prefix).toMatch(/^gridl_live_/);
		});

		it('DELETE /api-keys/:id sends correct request', async () => {
			const fetch = mockFetch(204, {});
			client.setFetch(fetch);

			const result = await client.deleteApiKey('key-abc');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/api-keys/key-abc`, {
				method: 'DELETE',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
			expect(result).toBeUndefined();
		});

		it('DELETE /api-keys/:id encodes untrusted API key IDs', async () => {
			const fetch = mockFetch(204, {});
			client.setFetch(fetch);

			await client.deleteApiKey('../billing/subscription');

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/api-keys/..%2Fbilling%2Fsubscription`,
				expect.any(Object)
			);
		});

		it('GET /account returns customer profile', async () => {
			const expected: CustomerProfileResponse = {
				id: 'cust-1',
				name: 'Alice',
				email: 'alice@example.com',
				email_verified: true,
				billing_plan: 'free',
				created_at: '2026-01-15T00:00:00Z'
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getProfile();

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/account`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
			expect(result).toEqual(expected);
		});

		it('GET /account/export returns account export payload', async () => {
			const expected = {
				profile: {
					id: 'cust-export-1',
					name: 'Export User',
					email: 'export@example.com',
					email_verified: true,
					billing_plan: 'shared' as const,
					created_at: '2026-04-22T17:00:00Z'
				}
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.exportAccount();

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/account/export`, {
				method: 'GET',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				}
			});
			expect(result).toEqual(expected);
		});

		it('PATCH /account sends name update', async () => {
			const expected: CustomerProfileResponse = {
				id: 'cust-1',
				name: 'New Name',
				email: 'alice@example.com',
				email_verified: true,
				billing_plan: 'free',
				created_at: '2026-01-15T00:00:00Z'
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.updateProfile({ name: 'New Name' });

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/account`, {
				method: 'PATCH',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				},
				body: JSON.stringify({ name: 'New Name' })
			});
			expect(result).toEqual(expected);
		});

		it('POST /account/change-password sends password change', async () => {
			const fetch = mockFetch(204, {});
			client.setFetch(fetch);

			await client.changePassword({
				current_password: 'oldpass',
				new_password: 'newpass123'
			});

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/account/change-password`, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				},
				body: JSON.stringify({ current_password: 'oldpass', new_password: 'newpass123' })
			});
		});

		it('DELETE /account sends password re-auth payload', async () => {
			const fetch = mockFetch(204, {});
			client.setFetch(fetch);

			const result = await client.deleteAccount('current-password-123');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/account`, {
				method: 'DELETE',
				headers: {
					'Content-Type': 'application/json',
					Authorization: 'Bearer my-jwt-token'
				},
				body: JSON.stringify({ password: 'current-password-123' })
			});
			expect(result).toBeUndefined();
		});

	});
});
