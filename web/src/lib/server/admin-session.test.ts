import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

import {
	ADMIN_SESSION_COOKIE,
	DEFAULT_ADMIN_LOGIN_LOCKOUT_SECONDS,
	DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS,
	DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS,
	MAX_ADMIN_SESSION_ABSOLUTE_LIFETIME_SECONDS,
	checkAdminLoginRateLimit,
	clearAdminLoginAttemptsForTest,
	createDurableAdminSession,
	requireDurableAdminSession,
	resetAdminLoginAttempts,
	resolveAdminSessionMaxAgeSeconds,
	revokeAllDurableAdminSessions,
	revokeCurrentDurableAdminSession,
	validateDurableAdminSession
} from './admin-session';
import {
	ADMIN_TEST_LOCALS,
	DURABLE_SESSION_OPERATOR_ID,
	DurableAdminSessionApi,
	MockCookies,
	OPAQUE_DURABLE_SESSION_TOKEN,
	REGISTERED_ADMIN_KEY,
	REQUESTED_SESSION_MAX_AGE_SECONDS,
	authenticatedAdminCookies
} from '../../routes/admin/admin_session_durable_test_support';

const LEGACY_LOCAL_SESSION_EXPORTS = [
	'createAdminSession',
	'getAdminSession',
	'revokeAdminSession',
	'purgeExpiredAdminSessions',
	'clearAdminSessionsForTest',
	'adminKeysMatch'
];

function sessionEvent(api: DurableAdminSessionApi, cookies: MockCookies = new MockCookies()) {
	return { fetch: api.fetch, cookies, locals: ADMIN_TEST_LOCALS };
}

beforeEach(() => {
	process.env.ADMIN_KEY = REGISTERED_ADMIN_KEY;
	clearAdminLoginAttemptsForTest();
});

afterEach(() => {
	delete process.env.ADMIN_KEY;
	clearAdminLoginAttemptsForTest();
});

describe('resolveAdminSessionMaxAgeSeconds', () => {
	it('returns default for undefined', () => {
		expect(resolveAdminSessionMaxAgeSeconds(undefined)).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for empty string', () => {
		expect(resolveAdminSessionMaxAgeSeconds('')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for whitespace-only', () => {
		expect(resolveAdminSessionMaxAgeSeconds('   ')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('parses valid integer string', () => {
		expect(resolveAdminSessionMaxAgeSeconds('3600')).toBe(3600);
	});

	it('trims whitespace before parsing', () => {
		expect(resolveAdminSessionMaxAgeSeconds('  7200  ')).toBe(7200);
	});

	it('returns default for zero', () => {
		expect(resolveAdminSessionMaxAgeSeconds('0')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for negative', () => {
		expect(resolveAdminSessionMaxAgeSeconds('-1')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for non-numeric string', () => {
		expect(resolveAdminSessionMaxAgeSeconds('abc')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for float', () => {
		expect(resolveAdminSessionMaxAgeSeconds('3.14')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('returns default for leading zero', () => {
		expect(resolveAdminSessionMaxAgeSeconds('01')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('clamps configured absolute lifetime to the planned 24-hour cap', () => {
		expect(resolveAdminSessionMaxAgeSeconds('90000')).toBe(
			MAX_ADMIN_SESSION_ABSOLUTE_LIFETIME_SECONDS
		);
	});

	it('leaves a value exactly at the cap untouched', () => {
		expect(
			resolveAdminSessionMaxAgeSeconds(String(MAX_ADMIN_SESSION_ABSOLUTE_LIFETIME_SECONDS))
		).toBe(MAX_ADMIN_SESSION_ABSOLUTE_LIFETIME_SECONDS);
	});
});

describe('durable admin session boundary', () => {
	it('exposes no local session mint, verifier, or key comparator', async () => {
		const adminSessionModule = await import('./admin-session');

		for (const legacyExport of LEGACY_LOCAL_SESSION_EXPORTS) {
			expect(adminSessionModule).not.toHaveProperty(legacyExport);
		}
	});

	it('mints a session by sending only the submitted key to POST /admin/sessions', async () => {
		const api = new DurableAdminSessionApi();

		const result = await createDurableAdminSession(
			sessionEvent(api),
			REGISTERED_ADMIN_KEY,
			REQUESTED_SESSION_MAX_AGE_SECONDS
		);

		expect(result).toEqual({ ok: true, sessionToken: OPAQUE_DURABLE_SESSION_TOKEN });
		expect(api.fetch).toHaveBeenCalledTimes(1);
		const [input, init] = api.fetch.mock.calls[0];
		const request = input instanceof Request ? input : new Request(input, init);
		expect(request.method).toBe('POST');
		expect(request.url).toBe('https://api.test/admin/sessions');
		expect(request.headers.get('x-admin-key')).toBe(REGISTERED_ADMIN_KEY);
		expect(request.headers.get('x-admin-session')).toBeNull();
		await expect(request.clone().json()).resolves.toEqual({
			max_age_seconds: REQUESTED_SESSION_MAX_AGE_SECONDS
		});
	});

	it('reports an API credential rejection separately from an API outage', async () => {
		const rejecting = new DurableAdminSessionApi();
		await expect(
			createDurableAdminSession(sessionEvent(rejecting), 'wrong-key', 3600)
		).resolves.toEqual({ ok: false, reason: 'invalid_credential' });

		const unavailable = new DurableAdminSessionApi();
		unavailable.failCreateWithServerError();
		await expect(
			createDurableAdminSession(sessionEvent(unavailable), REGISTERED_ADMIN_KEY, 3600)
		).resolves.toEqual({ ok: false, reason: 'unavailable' });
	});

	it('does not reuse ADMIN_KEY as a signing key when minting a session', async () => {
		const api = new DurableAdminSessionApi();
		process.env.ADMIN_KEY = 'server-side-admin-key';

		const result = await createDurableAdminSession(sessionEvent(api), 'operator-typed-key', 3600);

		// The server key is irrelevant to the outcome: only the submitted key
		// reaches the API, and only the API decides whether it is an operator.
		expect(result).toEqual({ ok: false, reason: 'invalid_credential' });
		const [input, init] = api.fetch.mock.calls[0];
		const request = input instanceof Request ? input : new Request(input, init);
		expect(request.headers.get('x-admin-key')).toBe('operator-typed-key');
	});

	it('validates a live session against GET /admin/sessions/current', async () => {
		const api = new DurableAdminSessionApi();

		await expect(
			validateDurableAdminSession(sessionEvent(api), OPAQUE_DURABLE_SESSION_TOKEN)
		).resolves.toEqual({ operatorId: DURABLE_SESSION_OPERATOR_ID });

		const [input, init] = api.fetch.mock.calls[0];
		const request = input instanceof Request ? input : new Request(input, init);
		expect(request.method).toBe('GET');
		expect(request.url).toBe('https://api.test/admin/sessions/current');
		expect(request.headers.get('x-admin-session')).toBe(OPAQUE_DURABLE_SESSION_TOKEN);
		expect(request.headers.get('x-admin-key')).toBeNull();
	});

	it('fails closed for missing, empty, and malformed cookie values without calling the API', async () => {
		const api = new DurableAdminSessionApi();

		for (const cookieValue of [undefined, '']) {
			await expect(validateDurableAdminSession(sessionEvent(api), cookieValue)).resolves.toBeNull();
		}
		expect(api.fetch).not.toHaveBeenCalled();

		await expect(
			validateDurableAdminSession(sessionEvent(api), 'not-an-api-issued-token')
		).resolves.toBeNull();
		expect(api.fetch).toHaveBeenCalledTimes(1);
	});

	it('fails closed when the API rejects or is unreachable', async () => {
		const revoked = new DurableAdminSessionApi();
		revoked.revokeSession();
		await expect(
			validateDurableAdminSession(sessionEvent(revoked), OPAQUE_DURABLE_SESSION_TOKEN)
		).resolves.toBeNull();

		const unreachable = {
			fetch: vi.fn().mockRejectedValue(new Error('connect ECONNREFUSED')),
			cookies: new MockCookies(),
			locals: ADMIN_TEST_LOCALS
		};
		await expect(
			validateDurableAdminSession(unreachable as never, OPAQUE_DURABLE_SESSION_TOKEN)
		).resolves.toBeNull();
	});

	it('makes a copied cookie stop validating once the API revokes the session', async () => {
		const api = new DurableAdminSessionApi();
		const copiedCookie = OPAQUE_DURABLE_SESSION_TOKEN;

		await expect(
			validateDurableAdminSession(sessionEvent(api), copiedCookie)
		).resolves.not.toBeNull();

		await revokeCurrentDurableAdminSession(sessionEvent(api), OPAQUE_DURABLE_SESSION_TOKEN);

		await expect(validateDurableAdminSession(sessionEvent(api), copiedCookie)).resolves.toBeNull();
	});

	it('revokes the current session with DELETE /admin/sessions/current', async () => {
		const api = new DurableAdminSessionApi();

		await revokeCurrentDurableAdminSession(sessionEvent(api), OPAQUE_DURABLE_SESSION_TOKEN);

		const [input, init] = api.fetch.mock.calls.at(-1)!;
		const request = input instanceof Request ? input : new Request(input, init);
		expect(request.method).toBe('DELETE');
		expect(request.url).toBe('https://api.test/admin/sessions/current');
		expect(request.headers.get('x-admin-session')).toBe(OPAQUE_DURABLE_SESSION_TOKEN);
	});

	it('revokes every operator session with DELETE /admin/sessions', async () => {
		const api = new DurableAdminSessionApi();

		await revokeAllDurableAdminSessions(sessionEvent(api), OPAQUE_DURABLE_SESSION_TOKEN);

		const [input, init] = api.fetch.mock.calls.at(-1)!;
		const request = input instanceof Request ? input : new Request(input, init);
		expect(request.method).toBe('DELETE');
		expect(request.url).toBe('https://api.test/admin/sessions');
		expect(request.headers.get('x-admin-session')).toBe(OPAQUE_DURABLE_SESSION_TOKEN);
		// Revoke-all must invalidate this operator's own cookie too.
		await expect(
			validateDurableAdminSession(sessionEvent(api), OPAQUE_DURABLE_SESSION_TOKEN)
		).resolves.toBeNull();
	});

	it('swallows revocation failures so logout can still clear the cookie', async () => {
		const api = new DurableAdminSessionApi();
		api.revokeSession();

		await expect(
			revokeCurrentDurableAdminSession(sessionEvent(api), OPAQUE_DURABLE_SESSION_TOKEN)
		).resolves.toBeUndefined();
	});

	it('skips revocation entirely when there is no cookie', async () => {
		const api = new DurableAdminSessionApi();

		await revokeCurrentDurableAdminSession(sessionEvent(api), undefined);
		await revokeAllDurableAdminSessions(sessionEvent(api), undefined);

		expect(api.fetch).not.toHaveBeenCalled();
	});
});

describe('requireDurableAdminSession', () => {
	it('returns operator identity and a session-authenticated admin client', async () => {
		const api = new DurableAdminSessionApi();

		const session = await requireDurableAdminSession(
			sessionEvent(api, authenticatedAdminCookies())
		);

		expect(session.operatorId).toBe(DURABLE_SESSION_OPERATOR_ID);

		api.fetch.mockClear();
		api.fetch.mockResolvedValueOnce(Response.json([]));
		await session.adminClient.getFleet();
		const [input, init] = api.fetch.mock.calls[0];
		const request = input instanceof Request ? input : new Request(input, init);
		expect(request.url).toBe('https://api.test/admin/fleet');
		expect(request.headers.get('x-admin-session')).toBe(OPAQUE_DURABLE_SESSION_TOKEN);
		expect(request.headers.get('x-admin-key')).toBeNull();
	});

	it('redirects to login without building a client when the cookie is missing', async () => {
		const api = new DurableAdminSessionApi();

		await expect(
			requireDurableAdminSession(sessionEvent(api, new MockCookies()))
		).rejects.toMatchObject({ status: 303, location: '/admin/login' });
		expect(api.fetch).not.toHaveBeenCalled();
	});

	it('redirects to login when the API rejects the cookie', async () => {
		const api = new DurableAdminSessionApi();
		api.revokeSession();

		await expect(
			requireDurableAdminSession(sessionEvent(api, authenticatedAdminCookies()))
		).rejects.toMatchObject({ status: 303, location: '/admin/login' });
		expect(api.fetch).toHaveBeenCalledTimes(1);
	});

	it('redirects to login for a forged cookie value', async () => {
		const api = new DurableAdminSessionApi();
		const cookies = new MockCookies({ [ADMIN_SESSION_COOKIE]: 'forged.session-token' });

		await expect(requireDurableAdminSession(sessionEvent(api, cookies))).rejects.toMatchObject({
			status: 303,
			location: '/admin/login'
		});
	});
});

describe('admin login rate limiting', () => {
	it('allows attempts within limit', () => {
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			const result = checkAdminLoginRateLimit('192.168.1.1');
			expect(result.blocked).toBe(false);
		}
	});

	it('blocks after exceeding attempt limit', () => {
		const ip = '10.0.0.1';
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			checkAdminLoginRateLimit(ip);
		}
		// One more should trigger lockout
		const result = checkAdminLoginRateLimit(ip);
		expect(result.blocked).toBe(true);
		expect(result.retryAfterSeconds).toBe(DEFAULT_ADMIN_LOGIN_LOCKOUT_SECONDS);
	});

	it('different IPs are independent', () => {
		// Exhaust IP 1
		for (let i = 0; i <= DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			checkAdminLoginRateLimit('1.1.1.1');
		}
		// IP 2 should still be fine
		const result = checkAdminLoginRateLimit('2.2.2.2');
		expect(result.blocked).toBe(false);
	});

	it('resetAdminLoginAttempts clears the counter', () => {
		const ip = '10.0.0.2';
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			checkAdminLoginRateLimit(ip);
		}
		resetAdminLoginAttempts(ip);
		// Should be allowed again
		const result = checkAdminLoginRateLimit(ip);
		expect(result.blocked).toBe(false);
	});
});
