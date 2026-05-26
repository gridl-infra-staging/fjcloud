import { describe, expect, it, vi } from 'vitest';
import {
	callWithBearerTokenRefreshOnResponse,
	callWithBearerTokenRefreshOnUnauthorizedThrow,
	FixtureAuthTokenInvalidError
} from '../../tests/fixtures/fixtures';

describe('callWithBearerTokenRefreshOnResponse', () => {
	it('returns the first response when it is not 401/403 without refreshing the token', async () => {
		const getToken = vi.fn<() => Promise<string>>().mockResolvedValueOnce('token-a');
		const invalidateToken = vi.fn<() => void>();
		const invoke = vi
			.fn<(token: string) => Promise<Response>>()
			.mockResolvedValueOnce(new Response('{}', { status: 200 }));

		const res = await callWithBearerTokenRefreshOnResponse({
			getToken,
			invalidateToken,
			invoke
		});

		expect(res.status).toBe(200);
		expect(invoke).toHaveBeenCalledTimes(1);
		expect(invoke).toHaveBeenNthCalledWith(1, 'token-a');
		expect(invalidateToken).not.toHaveBeenCalled();
		expect(getToken).toHaveBeenCalledTimes(1);
	});

	it.each([401, 403])(
		'invalidates the cached token and retries once with a refreshed token on %s',
		async (unauthorizedStatus) => {
			const getToken = vi
				.fn<() => Promise<string>>()
				.mockResolvedValueOnce('stale-token')
				.mockResolvedValueOnce('fresh-token');
			const invalidateToken = vi.fn<() => void>();
			const invoke = vi
				.fn<(token: string) => Promise<Response>>()
				.mockResolvedValueOnce(
					new Response('{"error":"unauthorized"}', { status: unauthorizedStatus })
				)
				.mockResolvedValueOnce(new Response('{}', { status: 200 }));

			const res = await callWithBearerTokenRefreshOnResponse({
				getToken,
				invalidateToken,
				invoke
			});

			expect(res.status).toBe(200);
			expect(invoke).toHaveBeenNthCalledWith(1, 'stale-token');
			expect(invoke).toHaveBeenNthCalledWith(2, 'fresh-token');
			expect(invalidateToken).toHaveBeenCalledTimes(1);
			expect(getToken).toHaveBeenCalledTimes(2);
		}
	);

	it('returns the second response even if the refresh attempt also returns unauthorized', async () => {
		const getToken = vi
			.fn<() => Promise<string>>()
			.mockResolvedValueOnce('stale-token')
			.mockResolvedValueOnce('fresh-token');
		const invalidateToken = vi.fn<() => void>();
		const invoke = vi
			.fn<(token: string) => Promise<Response>>()
			.mockResolvedValueOnce(new Response('{}', { status: 401 }))
			.mockResolvedValueOnce(new Response('{"error":"still unauthorized"}', { status: 401 }));

		const res = await callWithBearerTokenRefreshOnResponse({
			getToken,
			invalidateToken,
			invoke
		});

		expect(res.status).toBe(401);
		expect(invoke).toHaveBeenCalledTimes(2);
		expect(invalidateToken).toHaveBeenCalledTimes(1);
	});
});

describe('callWithBearerTokenRefreshOnUnauthorizedThrow', () => {
	it('returns the operation result without refreshing on success', async () => {
		const getToken = vi.fn<() => Promise<string>>().mockResolvedValueOnce('token-a');
		const invalidateToken = vi.fn<() => void>();
		const invoke = vi.fn<(token: string) => Promise<string>>().mockResolvedValueOnce('customer-1');

		const result = await callWithBearerTokenRefreshOnUnauthorizedThrow({
			getToken,
			invalidateToken,
			invoke
		});

		expect(result).toBe('customer-1');
		expect(invoke).toHaveBeenCalledTimes(1);
		expect(invoke).toHaveBeenCalledWith('token-a');
		expect(invalidateToken).not.toHaveBeenCalled();
	});

	it('refreshes and retries when the operation throws FixtureAuthTokenInvalidError', async () => {
		const getToken = vi
			.fn<() => Promise<string>>()
			.mockResolvedValueOnce('stale-token')
			.mockResolvedValueOnce('fresh-token');
		const invalidateToken = vi.fn<() => void>();
		const invoke = vi
			.fn<(token: string) => Promise<string>>()
			.mockRejectedValueOnce(new FixtureAuthTokenInvalidError(401, 'stale'))
			.mockResolvedValueOnce('customer-1');

		const result = await callWithBearerTokenRefreshOnUnauthorizedThrow({
			getToken,
			invalidateToken,
			invoke
		});

		expect(result).toBe('customer-1');
		expect(invoke).toHaveBeenNthCalledWith(1, 'stale-token');
		expect(invoke).toHaveBeenNthCalledWith(2, 'fresh-token');
		expect(invalidateToken).toHaveBeenCalledTimes(1);
	});

	it('propagates non-auth errors without refreshing', async () => {
		const getToken = vi.fn<() => Promise<string>>().mockResolvedValueOnce('token-a');
		const invalidateToken = vi.fn<() => void>();
		const invoke = vi
			.fn<(token: string) => Promise<string>>()
			.mockRejectedValueOnce(new Error('upstream timeout'));

		await expect(
			callWithBearerTokenRefreshOnUnauthorizedThrow({
				getToken,
				invalidateToken,
				invoke
			})
		).rejects.toThrow('upstream timeout');

		expect(invoke).toHaveBeenCalledTimes(1);
		expect(invalidateToken).not.toHaveBeenCalled();
	});

	it('propagates the refreshed-attempt error when the second call still rejects with FixtureAuthTokenInvalidError', async () => {
		const getToken = vi
			.fn<() => Promise<string>>()
			.mockResolvedValueOnce('stale-token')
			.mockResolvedValueOnce('fresh-token');
		const invalidateToken = vi.fn<() => void>();
		const invoke = vi
			.fn<(token: string) => Promise<string>>()
			.mockRejectedValueOnce(new FixtureAuthTokenInvalidError(401, 'stale'))
			.mockRejectedValueOnce(new FixtureAuthTokenInvalidError(401, 'still stale'));

		await expect(
			callWithBearerTokenRefreshOnUnauthorizedThrow({
				getToken,
				invalidateToken,
				invoke
			})
		).rejects.toBeInstanceOf(FixtureAuthTokenInvalidError);

		expect(invoke).toHaveBeenCalledTimes(2);
		expect(invalidateToken).toHaveBeenCalledTimes(1);
	});
});
