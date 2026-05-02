import { beforeEach, describe, expect, it, vi } from 'vitest';

const { fetchMock, getApiBaseUrlMock } = vi.hoisted(() => ({
	fetchMock: vi.fn(),
	getApiBaseUrlMock: vi.fn(() => 'https://api.example.com')
}));

vi.stubGlobal('fetch', fetchMock);

vi.mock('$lib/config', () => ({
	getApiBaseUrl: getApiBaseUrlMock
}));

import { GET } from './+server';

function makeRequestEvent(options: { user?: { token: string } | null } = {}): unknown {
	const user = options.user === undefined ? { token: 'jwt-token' } : options.user;
	return {
		request: new Request('http://localhost/api/stripe/publishable-key', {
			method: 'GET'
		}),
		locals: { user },
		params: {}
	} as never;
}

describe('GET /api/stripe/publishable-key', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		getApiBaseUrlMock.mockReturnValue('https://api.example.com');
	});

	it('returns 401 unauthorized when request is unauthenticated', async () => {
		const response = await GET(makeRequestEvent({ user: null }) as never);
		expect(response.status).toBe(401);
		expect(await response.json()).toEqual({ error: 'unauthorized' });
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('returns 200 publishable key payload from the backend', async () => {
		fetchMock.mockResolvedValueOnce(
			new Response(JSON.stringify({ publishableKey: 'pk_test_123' }), {
				status: 200,
				headers: { 'Content-Type': 'application/json' }
			})
		);

		const response = await GET(makeRequestEvent() as never);

		expect(fetchMock).toHaveBeenCalledWith('https://api.example.com/billing/publishable-key', {
			method: 'GET',
			headers: {
				Authorization: 'Bearer jwt-token'
			}
		});
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ publishableKey: 'pk_test_123' });
	});

	it('forwards backend status and error body without translation', async () => {
		fetchMock.mockResolvedValueOnce(
			new Response(JSON.stringify({ error: 'stripe_publishable_key_unavailable' }), {
				status: 503,
				headers: { 'Content-Type': 'application/json' }
			})
		);

		const response = await GET(makeRequestEvent() as never);
		expect(response.status).toBe(503);
		expect(await response.json()).toEqual({ error: 'stripe_publishable_key_unavailable' });
	});

	it('returns 503 unavailable payload when upstream fetch rejects', async () => {
		fetchMock.mockRejectedValueOnce(new TypeError('fetch failed'));

		const response = await GET(makeRequestEvent() as never);
		expect(response.status).toBe(503);
		expect(await response.json()).toEqual({ error: 'stripe_publishable_key_unavailable' });
	});
});
