import { afterEach, describe, expect, it, vi } from 'vitest';
import { __fixtureTestSeams } from '../../tests/fixtures/fixtures';
import { PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV } from '../../playwright.config.contract';

const ORIGINAL_ENV = { ...process.env };

function jsonResponse(status: number, body: Record<string, unknown>): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

describe('fresh-signup verification state probe', () => {
	afterEach(() => {
		vi.unstubAllGlobals();
		for (const key of Object.keys(process.env)) {
			delete process.env[key];
		}
		for (const [key, value] of Object.entries(ORIGINAL_ENV)) {
			process.env[key] = value;
		}
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

	it('requires a Mailpit token without consulting the local auto-verification sentinel', async () => {
		process.env[PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION_ENV] = '1';
		process.env.MAILPIT_API_URL = 'http://localhost:8025';
		const verificationToken = 'mailpit_verification_token_123';
		const fetchMock = vi.fn<typeof fetch>(async (input) => {
			const url = new URL(String(input));
			if (url.pathname === '/api/v1/search') {
				return jsonResponse(200, {
					messages: [{ ID: 'message-1' }]
				});
			}
			if (url.pathname === '/api/v1/message/message-1') {
				return jsonResponse(200, {
					HTML: `<a href="http://localhost:5173/verify-email/${verificationToken}">Verify</a>`
				});
			}
			if (url.pathname === '/auth/login') {
				return jsonResponse(200, { token: 'fresh-signup-token' });
			}
			if (url.pathname === '/account') {
				return jsonResponse(200, { email_verified: true });
			}
			throw new Error(`unexpected fetch: ${url.href}`);
		});
		vi.stubGlobal('fetch', fetchMock);

		await expect(
			__fixtureTestSeams.resolveFreshSignupVerificationTokenOrAutoVerifiedSentinel(
				'real-token@e2e.griddle.test',
				'TestPassword123!'
			)
		).resolves.toBe(verificationToken);
		expect(fetchMock.mock.calls.map(([url]) => new URL(String(url)).pathname)).toEqual([
			'/api/v1/search',
			'/api/v1/message/message-1'
		]);
	});
});
