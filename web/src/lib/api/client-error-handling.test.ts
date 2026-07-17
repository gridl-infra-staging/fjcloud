import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiClient, ApiRequestError } from './client';
import { BASE_URL, mockFetch, createClient } from './client.test.shared';

// Error-handling and health-check coverage extracted from client.test.ts
// to keep that file under the 800-line size cap.
describe('ApiClient error handling', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createClient();
	});

	it('throws ApiRequestError on non-ok response', async () => {
		const fetch = mockFetch(409, { error: 'email already registered' });
		client.setFetch(fetch);

		await expect(
			client.register({ name: 'A', email: 'dup@test.com', password: '12345678' })
		).rejects.toThrow(ApiRequestError);
	});

	it('ApiRequestError contains status and message from response', async () => {
		const fetch = mockFetch(400, { error: 'invalid email' });
		client.setFetch(fetch);

		try {
			await client.login({ email: 'bad', password: 'x' });
			expect.fail('should have thrown');
		} catch (e) {
			expect(e).toBeInstanceOf(ApiRequestError);
			const err = e as ApiRequestError;
			expect(err.status).toBe(400);
			expect(err.message).toBe('invalid email');
		}
	});

	it('ApiRequestError preserves x-request-id and response headers from backend errors', async () => {
		const fetch = vi.fn().mockResolvedValue(
			new Response(JSON.stringify({ error: 'service unavailable' }), {
				status: 503,
				headers: {
					'content-type': 'application/json',
					'x-request-id': 'req-test-123'
				}
			})
		);
		client.setFetch(fetch);

		try {
			await client.healthCheck();
			expect.fail('should have thrown');
		} catch (e) {
			expect(e).toBeInstanceOf(ApiRequestError);
			const err = e as ApiRequestError;
			expect(err.status).toBe(503);
			expect(err.message).toBe('service unavailable');
			expect(err.requestId).toBe('req-test-123');
			expect(err.headers?.get('x-request-id')).toBe('req-test-123');
		}
	});

	it('falls back to unknown error when non-JSON error response is returned', async () => {
		const fetch = vi.fn().mockResolvedValue(
			new Response('this-is-not-json', {
				status: 502,
				headers: {
					'content-type': 'application/json',
					'x-request-id': 'req-test-nonjson-456'
				}
			})
		);
		client.setFetch(fetch);

		try {
			await client.healthCheck();
			expect.fail('should have thrown');
		} catch (e) {
			expect(e).toBeInstanceOf(ApiRequestError);
			const err = e as ApiRequestError;
			expect(err.status).toBe(502);
			expect(err.message).toBe('unknown error');
			expect(err.requestId).toBe('req-test-nonjson-456');
			expect(err.headers?.get('x-request-id')).toBe('req-test-nonjson-456');
		}
	});

	it('handles network errors gracefully', async () => {
		const fetch = vi.fn().mockRejectedValue(new Error('network failure'));
		client.setFetch(fetch);

		await expect(client.healthCheck()).rejects.toThrow('network failure');
	});
});

describe('ApiClient health check', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createClient();
	});

	it('GET /health with no auth', async () => {
		const fetch = mockFetch(200, { status: 'ok' });
		client.setFetch(fetch);

		await client.healthCheck();

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/health`, {
			method: 'GET',
			headers: { 'Content-Type': 'application/json' }
		});
	});
});
