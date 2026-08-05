import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

import {
	ADMIN_SESSION_COOKIE,
	DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS,
	checkAdminLoginRateLimit,
	clearAdminLoginAttemptsForTest
} from '$lib/server/admin-session';
import { _extractClientIp as extractClientIp, actions } from './+page.server';
import {
	ADMIN_TEST_LOCALS,
	DurableAdminSessionApi,
	MockCookies,
	OPAQUE_DURABLE_SESSION_TOKEN,
	REGISTERED_ADMIN_KEY,
	REQUESTED_SESSION_MAX_AGE_SECONDS,
	durableSessionFetchMock
} from '../admin_session_durable_test_support';

// Credentials the login action must never resolve locally; only the API decides.
const SERVER_SIDE_ADMIN_KEY = 'server-side-admin-key';

beforeEach(() => {
	process.env.ADMIN_KEY = SERVER_SIDE_ADMIN_KEY;
	delete process.env.ADMIN_SESSION_MAX_AGE_SECONDS;
	clearAdminLoginAttemptsForTest();
});

afterEach(() => {
	clearAdminLoginAttemptsForTest();
	delete process.env.ADMIN_KEY;
	delete process.env.ADMIN_SESSION_MAX_AGE_SECONDS;
});

describe('extractClientIp', () => {
	it('returns the framework-provided client address', () => {
		expect(extractClientIp(() => '10.0.0.1')).toBe('10.0.0.1');
	});

	it('trims whitespace from the client address', () => {
		expect(extractClientIp(() => '  203.0.113.50  ')).toBe('203.0.113.50');
	});

	it('returns unknown when getClientAddress is unavailable', () => {
		expect(extractClientIp(undefined)).toBe('unknown');
	});

	it('returns unknown when getClientAddress throws', () => {
		expect(
			extractClientIp(() => {
				throw new Error('adapter does not expose client IP');
			})
		).toBe('unknown');
	});

	it('returns unknown for an empty client address', () => {
		expect(extractClientIp(() => '   ')).toBe('unknown');
	});
});

describe('admin login action session contracts', () => {
	it('FJ-R-AUTHZ-02 issues the opaque durable API token minted from the submitted key', async () => {
		const cookies = new MockCookies();
		const fetch = durableSessionFetchMock();
		const request = new Request('https://localhost/admin/login', {
			method: 'POST',
			body: new URLSearchParams({ admin_key: REGISTERED_ADMIN_KEY })
		});

		await expect(
			actions.default({
				request,
				cookies,
				url: new URL('https://localhost/admin/login'),
				getClientAddress: () => '203.0.113.70',
				locals: ADMIN_TEST_LOCALS,
				fetch
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/fleet'
		});

		expect(cookies.setCalls).toHaveLength(1);
		const setCall = cookies.setCalls[0];
		expect(setCall.name).toBe(ADMIN_SESSION_COOKIE);
		expect(setCall.options).toMatchObject({
			httpOnly: true,
			secure: true,
			sameSite: 'lax',
			path: '/admin',
			maxAge: REQUESTED_SESSION_MAX_AGE_SECONDS
		});
		expect(setCall.value).toBe(OPAQUE_DURABLE_SESSION_TOKEN);

		expect(fetch).toHaveBeenCalledTimes(1);
		const [input, init] = fetch.mock.calls[0];
		const apiRequest = input instanceof Request ? input : new Request(input, init);
		expect(apiRequest.url).toBe('https://api.test/admin/sessions');
		expect(apiRequest.method).toBe('POST');
		// The submitted key travels to the API; the server-side ADMIN_KEY does not.
		expect(apiRequest.headers.get('x-admin-key')).toBe(REGISTERED_ADMIN_KEY);
		expect(apiRequest.headers.get('x-admin-key')).not.toBe(SERVER_SIDE_ADMIN_KEY);
		expect(apiRequest.headers.get('x-admin-session')).toBeNull();
		await expect(apiRequest.clone().json()).resolves.toEqual({
			max_age_seconds: REQUESTED_SESSION_MAX_AGE_SECONDS
		});
	});

	it('rejects a key that only matches the web-local ADMIN_KEY', async () => {
		const cookies = new MockCookies();
		const fetch = durableSessionFetchMock();
		const request = new Request('https://localhost/admin/login', {
			method: 'POST',
			body: new URLSearchParams({ admin_key: SERVER_SIDE_ADMIN_KEY })
		});

		const result = await actions.default({
			request,
			cookies,
			url: new URL('https://localhost/admin/login'),
			getClientAddress: () => '203.0.113.72',
			locals: ADMIN_TEST_LOCALS,
			fetch
		} as never);

		expect(result.status).toBe(401);
		expect(result.data.errors.form).toBe('Invalid admin key');
		expect(cookies.setCalls).toHaveLength(0);
	});

	it('leaves the throttle counter intact when the API rejects the credential', async () => {
		const clientIp = '203.0.113.73';
		const api = new DurableAdminSessionApi();
		for (let attempt = 0; attempt < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; attempt += 1) {
			const request = new Request('https://localhost/admin/login', {
				method: 'POST',
				body: new URLSearchParams({ admin_key: 'wrong-key' })
			});
			const result = await actions.default({
				request,
				cookies: new MockCookies(),
				url: new URL('https://localhost/admin/login'),
				getClientAddress: () => clientIp,
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never);
			expect(result.status).toBe(401);
		}

		// Failed attempts must still accumulate to a lockout.
		expect(checkAdminLoginRateLimit(clientIp).blocked).toBe(true);
	});

	it('preserves per-IP throttling while issuing durable admin cookies', async () => {
		const clientIp = '203.0.113.71';
		for (let attempt = 0; attempt < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS - 1; attempt += 1) {
			expect(checkAdminLoginRateLimit(clientIp).blocked).toBe(false);
		}

		const cookies = new MockCookies();
		const fetch = durableSessionFetchMock();
		const request = new Request('http://localhost/admin/login', {
			method: 'POST',
			body: new URLSearchParams({ admin_key: REGISTERED_ADMIN_KEY })
		});

		await expect(
			actions.default({
				request,
				cookies,
				url: new URL('http://localhost/admin/login'),
				getClientAddress: () => clientIp,
				locals: ADMIN_TEST_LOCALS,
				fetch
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/fleet'
		});

		expect(cookies.setCalls).toHaveLength(1);
		expect(cookies.setCalls[0].options.path).toBe('/admin');
		expect(checkAdminLoginRateLimit(clientIp).blocked).toBe(false);
	});
});
