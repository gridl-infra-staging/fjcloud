import { describe, expect, it, vi } from 'vitest';
import { POST } from './+server';

// $env/dynamic/private is hoisted by SvelteKit's Vite plugin in vitest, so
// this route test must stub API_BASE_URL explicitly for deterministic proxy
// URL assertions.
vi.mock('$env/dynamic/private', () => ({
	env: { API_BASE_URL: 'http://127.0.0.1:3001' }
}));

describe('billing upgrade proxy route', () => {
	it('returns 401 when the dashboard session is missing', async () => {
		const response = await POST({
			locals: {},
			fetch: globalThis.fetch
		} as never);

		expect(response.status).toBe(401);
		await expect(response.json()).resolves.toEqual({ error: 'unauthorized' });
	});

	it('forwards the backend response body and auth header for authenticated requests', async () => {
		const fetchMock = async (input: RequestInfo | URL, init?: RequestInit) => {
			expect(String(input)).toBe('http://127.0.0.1:3001/billing/upgrade');
			expect(init?.method).toBe('POST');
			expect(init?.body).toBe('{}');
			expect((init?.headers as Record<string, string>).Authorization).toBe('Bearer jwt-token');
			return new Response(
				JSON.stringify({
					billing_plan: 'shared',
					subscription_cycle_anchor_at: '2026-05-17T12:00:00Z',
					stripe_invoice_id: 'in_test_123',
					activation_amount_cents: 500
				}),
				{
					status: 200,
					headers: { 'Content-Type': 'application/json' }
				}
			);
		};

		const response = await POST({
			locals: { user: { token: 'jwt-token' }, apiBaseUrl: 'http://127.0.0.1:3001' },
			fetch: fetchMock
		} as never);

		expect(response.status).toBe(200);
		await expect(response.json()).resolves.toEqual({
			billing_plan: 'shared',
			subscription_cycle_anchor_at: '2026-05-17T12:00:00Z',
			stripe_invoice_id: 'in_test_123',
			activation_amount_cents: 500
		});
	});
});
