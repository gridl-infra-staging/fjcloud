import { afterEach, describe, expect, it, vi } from 'vitest';
import { __fixtureTestSeams } from '../../tests/fixtures/fixtures';

function jsonResponse(status: number, body: Record<string, unknown>): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

describe('fresh-signup verification state probe', () => {
	afterEach(() => {
		vi.unstubAllGlobals();
	});

	it('does not mistake a successful login for verified email', async () => {
		const fetchMock = vi
			.fn<typeof fetch>()
			.mockResolvedValueOnce(jsonResponse(200, { token: 'fresh-signup-token' }))
			.mockResolvedValueOnce(jsonResponse(200, { email_verified: false }));
		vi.stubGlobal('fetch', fetchMock);

		await expect(
			__fixtureTestSeams.loginConfirmsFreshSignupAlreadyVerified(
				'fresh-signup@e2e.griddle.test',
				'TestPassword123!'
			)
		).resolves.toBe(false);
		expect(fetchMock.mock.calls.map(([url]) => new URL(String(url)).pathname)).toEqual([
			'/auth/login',
			'/account'
		]);
	});

	it('accepts the sentinel path only when the account endpoint reports verified email', async () => {
		const fetchMock = vi
			.fn<typeof fetch>()
			.mockResolvedValueOnce(jsonResponse(200, { token: 'auto-verified-token' }))
			.mockResolvedValueOnce(jsonResponse(200, { email_verified: true }));
		vi.stubGlobal('fetch', fetchMock);

		await expect(
			__fixtureTestSeams.loginConfirmsFreshSignupAlreadyVerified(
				'auto-verified@e2e.griddle.test',
				'TestPassword123!'
			)
		).resolves.toBe(true);
	});
});
