import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/admin/fleet') }
}));

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

import AdminLayout from './+layout.svelte';
import { load as adminLayoutLoad } from './+layout.server';
import { actions as loginActions } from './login/+page.server';
import { actions as logoutActions } from './logout/+page.server';
import {
	ADMIN_TEST_LOCALS,
	DurableAdminSessionApi,
	OPAQUE_DURABLE_SESSION_TOKEN,
	REGISTERED_ADMIN_KEY,
	REQUESTED_SESSION_MAX_AGE_SECONDS,
	MockCookies,
	authenticatedAdminCookies,
	durableSessionFetchMock
} from './admin_session_durable_test_support';
import {
	ADMIN_SESSION_COOKIE,
	DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS,
	clearAdminLoginAttemptsForTest,
	checkAdminLoginRateLimit,
	DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS,
	DEFAULT_ADMIN_LOGIN_LOCKOUT_SECONDS,
	resolveAdminSessionMaxAgeSeconds
} from '$lib/server/admin-session';

beforeEach(() => {
	process.env.ADMIN_KEY = REGISTERED_ADMIN_KEY;
	delete process.env.ENVIRONMENT;
	delete process.env.ADMIN_SESSION_MAX_AGE_SECONDS;
	clearAdminLoginAttemptsForTest();
});

afterEach(() => {
	cleanup();
	clearAdminLoginAttemptsForTest();
	delete process.env.ADMIN_KEY;
	delete process.env.ENVIRONMENT;
	delete process.env.ADMIN_SESSION_MAX_AGE_SECONDS;
});

describe('Admin layout and auth', () => {
	it('admin layout renders sidebar links, header, and logout', () => {
		render(AdminLayout, {
			data: {
				environment: 'staging',
				isAuthenticated: true
			},
			children: createRawSnippet(() => ({ render: () => '<span></span>' }))
		});

		expect(screen.getByRole('heading', { name: 'Admin Panel' })).toBeInTheDocument();
		expect(screen.getByText('staging')).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Fleet' })).toHaveAttribute('href', '/admin/fleet');
		expect(screen.getByRole('link', { name: 'Customers' })).toHaveAttribute(
			'href',
			'/admin/customers'
		);
		expect(screen.getByRole('link', { name: 'Migrations' })).toHaveAttribute(
			'href',
			'/admin/migrations'
		);
		expect(screen.getByRole('link', { name: 'Billing' })).toHaveAttribute('href', '/admin/billing');
		expect(screen.getByRole('link', { name: 'Alerts' })).toHaveAttribute('href', '/admin/alerts');
		expect(screen.getByRole('link', { name: 'Log Out' })).toHaveAttribute('href', '/admin/logout');
	});

	it('unauthenticated admin routes redirect to login', async () => {
		const cookies = new MockCookies();

		await expect(
			adminLayoutLoad({
				cookies,
				url: new URL('http://localhost/admin/fleet')
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/login'
		});
	});

	it('authenticated durable API session at /admin/login redirects to /admin/fleet', async () => {
		const api = new DurableAdminSessionApi();
		const cookies = authenticatedAdminCookies();

		await expect(
			adminLayoutLoad({
				cookies,
				url: new URL('http://localhost/admin/login'),
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/fleet'
		});
		expect(api.fetch).toHaveBeenCalledTimes(1);
	});

	it('authenticated durable API session at /admin redirects to /admin/fleet', async () => {
		const api = new DurableAdminSessionApi();
		const cookies = authenticatedAdminCookies();

		await expect(
			adminLayoutLoad({
				cookies,
				url: new URL('http://localhost/admin'),
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/fleet'
		});
		expect(api.fetch).toHaveBeenCalledTimes(1);
	});

	it('expired durable API session redirects to login', async () => {
		const api = new DurableAdminSessionApi();
		api.revokeSession();
		const cookies = authenticatedAdminCookies();

		await expect(
			adminLayoutLoad({
				cookies,
				url: new URL('http://localhost/admin/fleet'),
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/login'
		});
		expect(api.fetch).toHaveBeenCalledTimes(1);
	});

	it('layout server returns isAuthenticated without leaking session id', async () => {
		process.env.ENVIRONMENT = 'staging';
		const api = new DurableAdminSessionApi();
		const cookies = authenticatedAdminCookies();

		const result = await adminLayoutLoad({
			cookies,
			url: new URL('http://localhost/admin/fleet'),
			locals: ADMIN_TEST_LOCALS,
			fetch: api.fetch
		} as never);

		expect(result!.isAuthenticated).toBe(true);
		expect(result!.environment).toBe('staging');
		// Session ID must NOT be in the returned data (httpOnly cookie only)
		expect(result).not.toHaveProperty('adminSession');
		expect(JSON.stringify(result)).not.toContain(OPAQUE_DURABLE_SESSION_TOKEN);
	});

	it('layout server reads Cloudflare platform environment for durable sessions', async () => {
		delete process.env.ADMIN_KEY;
		const api = new DurableAdminSessionApi();
		const cookies = authenticatedAdminCookies();

		const result = await adminLayoutLoad({
			cookies,
			url: new URL('https://cloud.staging.flapjack.foo/admin/fleet'),
			platform: { env: { ADMIN_KEY: 'platform-admin-key', ENVIRONMENT: 'staging' } },
			locals: ADMIN_TEST_LOCALS,
			fetch: api.fetch
		} as never);

		expect(result!.isAuthenticated).toBe(true);
		expect(result!.environment).toBe('staging');
	});

	it('redirects a revoked durable API cookie to login', async () => {
		const api = new DurableAdminSessionApi();
		api.revokeSession();
		const cookies = authenticatedAdminCookies();

		await expect(
			adminLayoutLoad({
				cookies,
				url: new URL('http://localhost/admin/fleet'),
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/login'
		});
	});

	it('redirects copied durable API cookies on /admin after durable session state is gone', async () => {
		const api = new DurableAdminSessionApi();
		api.removeSession();
		const cookies = authenticatedAdminCookies();

		await expect(
			adminLayoutLoad({
				cookies,
				url: new URL('http://localhost/admin'),
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/login'
		});
	});

	it('redirects copied durable API cookies on /admin/fleet after durable session state is gone', async () => {
		const api = new DurableAdminSessionApi();
		api.removeSession();
		const cookies = authenticatedAdminCookies();

		await expect(
			adminLayoutLoad({
				cookies,
				url: new URL('http://localhost/admin/fleet'),
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/login'
		});
	});

	it('accepts the opaque API-issued session on the admin layout through durable validation', async () => {
		const api = new DurableAdminSessionApi();
		const cookies = authenticatedAdminCookies();
		const result = await adminLayoutLoad({
			cookies,
			url: new URL('https://localhost/admin/fleet'),
			locals: ADMIN_TEST_LOCALS,
			fetch: api.fetch
		} as never);
		expect(result!.isAuthenticated).toBe(true);
		const [input, init] = api.fetch.mock.calls.at(-1)!;
		const validationRequest = input instanceof Request ? input : new Request(input, init);
		expect(validationRequest.method).toBe('GET');
		expect(validationRequest.url).toBe('https://api.test/admin/sessions/current');
		expect(validationRequest.headers.get('x-admin-session')).toBe(OPAQUE_DURABLE_SESSION_TOKEN);
	});

	it('redirects an API-issued session missing from durable state on /admin', async () => {
		const api = new DurableAdminSessionApi();
		const cookies = authenticatedAdminCookies();
		api.removeSession();
		await expect(
			adminLayoutLoad({
				cookies,
				url: new URL('https://localhost/admin'),
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never)
		).rejects.toMatchObject({ status: 303, location: '/admin/login' });
		expect(api.fetch).toHaveBeenCalledTimes(1);
	});

	it('redirects a durably revoked API-issued session on /admin/fleet', async () => {
		const api = new DurableAdminSessionApi();
		const cookies = authenticatedAdminCookies();
		api.revokeSession();
		await expect(
			adminLayoutLoad({
				cookies,
				url: new URL('https://localhost/admin/fleet'),
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never)
		).rejects.toMatchObject({ status: 303, location: '/admin/login' });
		expect(api.fetch).toHaveBeenCalledTimes(1);
	});

	it('durably revokes the API-issued current session before deleting its cookie on logout', async () => {
		const operationLog: string[] = [];
		const api = new DurableAdminSessionApi(operationLog);
		const cookies = new MockCookies(
			{ [ADMIN_SESSION_COOKIE]: OPAQUE_DURABLE_SESSION_TOKEN },
			operationLog
		);
		await expect(
			logoutActions.default({
				cookies,
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never)
		).rejects.toMatchObject({ status: 303, location: '/admin/login' });
		expect(operationLog).toEqual(['api-revoke', 'cookie-delete']);
		const [input, init] = api.fetch.mock.calls.at(-1)!;
		const revokeRequest = input instanceof Request ? input : new Request(input, init);
		expect(revokeRequest.method).toBe('DELETE');
		expect(revokeRequest.url).toBe('https://api.test/admin/sessions/current');
		expect(revokeRequest.headers.get('x-admin-session')).toBe(OPAQUE_DURABLE_SESSION_TOKEN);
	});

	it('admin login validates key and creates secure durable session cookie for https', async () => {
		const cookies = new MockCookies();
		const fetch = durableSessionFetchMock();
		const request = new Request('https://localhost/admin/login', {
			method: 'POST',
			body: new URLSearchParams({ admin_key: REGISTERED_ADMIN_KEY })
		});

		await expect(
			loginActions.default({
				request,
				cookies,
				url: new URL('https://localhost/admin/login'),
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
		expect(setCall.options.httpOnly).toBe(true);
		expect(setCall.options.secure).toBe(true);
		expect(setCall.options.sameSite).toBe('lax');
		expect(setCall.options.path).toBe('/admin');
		expect(setCall.options.maxAge).toBe(REQUESTED_SESSION_MAX_AGE_SECONDS);
		expect(setCall.value).toBe(OPAQUE_DURABLE_SESSION_TOKEN);
	});

	it('admin login reads ADMIN_SESSION_MAX_AGE_SECONDS from Cloudflare platform env', async () => {
		delete process.env.ADMIN_KEY;
		const cookies = new MockCookies();
		const api = new DurableAdminSessionApi();
		const request = new Request('https://cloud.staging.flapjack.foo/admin/login', {
			method: 'POST',
			body: new URLSearchParams({ admin_key: REGISTERED_ADMIN_KEY })
		});

		await expect(
			loginActions.default({
				request,
				cookies,
				url: new URL('https://cloud.staging.flapjack.foo/admin/login'),
				platform: { env: { ADMIN_SESSION_MAX_AGE_SECONDS: '3600' } },
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/fleet'
		});

		expect(cookies.setCalls).toHaveLength(1);
		expect(cookies.setCalls[0].value).toBe(OPAQUE_DURABLE_SESSION_TOKEN);
		// The platform-configured lifetime governs both the API request and the cookie.
		expect(cookies.setCalls[0].options.maxAge).toBe(3600);
		const [input, init] = api.fetch.mock.calls[0];
		const apiRequest = input instanceof Request ? input : new Request(input, init);
		await expect(apiRequest.clone().json()).resolves.toEqual({ max_age_seconds: 3600 });
	});

	it('admin login uses a non-secure session cookie for local http', async () => {
		const cookies = new MockCookies();
		const fetch = durableSessionFetchMock();
		const request = new Request('http://localhost/admin/login', {
			method: 'POST',
			body: new URLSearchParams({ admin_key: REGISTERED_ADMIN_KEY })
		});

		await expect(
			loginActions.default({
				request,
				cookies,
				url: new URL('http://localhost/admin/login'),
				locals: ADMIN_TEST_LOCALS,
				fetch
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/fleet'
		});

		expect(cookies.setCalls).toHaveLength(1);
		expect(cookies.setCalls[0].options.secure).toBe(false);
		expect(cookies.setCalls[0].options.path).toBe('/admin');
		expect(cookies.setCalls[0].value).toBe(OPAQUE_DURABLE_SESSION_TOKEN);
	});

	it('a key the API rejects returns 401 without creating a session cookie', async () => {
		const cookies = new MockCookies();
		const request = new Request('http://localhost/admin/login', {
			method: 'POST',
			body: new URLSearchParams({ admin_key: 'wrong-key' })
		});

		const result = await loginActions.default({
			request,
			cookies,
			url: new URL('http://localhost/admin/login'),
			locals: ADMIN_TEST_LOCALS,
			fetch: durableSessionFetchMock()
		} as never);

		expect(result.status).toBe(401);
		expect(result.data.errors.form).toBe('Invalid admin key');
		expect(cookies.setCalls).toHaveLength(0);
	});

	it('empty admin key returns 400 validation error', async () => {
		const cookies = new MockCookies();
		const request = new Request('http://localhost/admin/login', {
			method: 'POST',
			body: new URLSearchParams({ admin_key: '   ' })
		});

		const result = await loginActions.default({
			request,
			cookies
		} as never);

		expect(result.status).toBe(400);
		expect(result.data.errors.admin_key).toBe('Admin key is required');
		expect(cookies.setCalls).toHaveLength(0);
	});

	it('an unavailable session API returns 502 rather than a credential error', async () => {
		const cookies = new MockCookies();
		const api = new DurableAdminSessionApi();
		api.failCreateWithServerError();
		const request = new Request('http://localhost/admin/login', {
			method: 'POST',
			body: new URLSearchParams({ admin_key: REGISTERED_ADMIN_KEY })
		});

		const result = await loginActions.default({
			request,
			cookies,
			url: new URL('http://localhost/admin/login'),
			locals: ADMIN_TEST_LOCALS,
			fetch: api.fetch
		} as never);

		expect(result.status).toBe(502);
		expect(result.data.errors.form).toBe('Admin authentication is temporarily unavailable');
		expect(cookies.setCalls).toHaveLength(0);
	});

	it('logout deletes cookie after durable revoke rejects the current session', async () => {
		const operationLog: string[] = [];
		const api = new DurableAdminSessionApi(operationLog);
		const cookies = new MockCookies(
			{ [ADMIN_SESSION_COOKIE]: OPAQUE_DURABLE_SESSION_TOKEN },
			operationLog
		);

		await expect(
			logoutActions.default({
				cookies,
				locals: ADMIN_TEST_LOCALS,
				fetch: api.fetch
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/login'
		});

		expect(operationLog).toEqual(['api-revoke', 'cookie-delete']);
		expect(cookies.deleteCalls).toHaveLength(1);
		expect(cookies.deleteCalls[0].name).toBe(ADMIN_SESSION_COOKIE);
		expect(cookies.deleteCalls[0].options.path).toBe('/admin');
	});
});

describe('Admin login rate limiting', () => {
	it('allows login attempts below the threshold', () => {
		const ip = '192.168.1.1';
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			const result = checkAdminLoginRateLimit(ip);
			expect(result.blocked).toBe(false);
		}
	});

	it('blocks login after exceeding max attempts', () => {
		const ip = '10.0.0.1';
		// Exhaust all attempts
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			checkAdminLoginRateLimit(ip);
		}
		// Next attempt should be blocked
		const result = checkAdminLoginRateLimit(ip);
		expect(result.blocked).toBe(true);
		expect(result.retryAfterSeconds).toBeGreaterThan(0);
		expect(result.retryAfterSeconds).toBeLessThanOrEqual(DEFAULT_ADMIN_LOGIN_LOCKOUT_SECONDS);
	});

	it('rate limit is per-IP (different IPs are independent)', () => {
		const ip1 = '10.0.0.1';
		const ip2 = '10.0.0.2';
		// Exhaust IP1
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			checkAdminLoginRateLimit(ip1);
		}
		expect(checkAdminLoginRateLimit(ip1).blocked).toBe(true);
		// IP2 should still be allowed
		expect(checkAdminLoginRateLimit(ip2).blocked).toBe(false);
	});

	it('login action returns 429 when rate limited', async () => {
		const ip = '203.0.113.5';
		// Exhaust rate limit
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			checkAdminLoginRateLimit(ip);
		}

		const cookies = new MockCookies();
		const request = new Request('http://localhost/admin/login', {
			method: 'POST',
			headers: { 'x-forwarded-for': ip },
			body: new URLSearchParams({ admin_key: 'wrong-key' })
		});

		const result = await loginActions.default({
			request,
			cookies,
			getClientAddress: () => ip
		} as never);

		expect(result.status).toBe(429);
		expect(result.data.errors.form).toContain('Too many login attempts');
		expect(cookies.setCalls).toHaveLength(0);
	});

	it('successful login resets rate limit counter for that IP', async () => {
		const ip = '203.0.113.10';
		// Use all but one attempt
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS - 1; i++) {
			checkAdminLoginRateLimit(ip);
		}

		const cookies = new MockCookies();
		const request = new Request('http://localhost/admin/login', {
			method: 'POST',
			headers: { 'x-forwarded-for': ip },
			body: new URLSearchParams({ admin_key: REGISTERED_ADMIN_KEY })
		});

		// Successful login should redirect (not blocked)
		await expect(
			loginActions.default({
				request,
				cookies,
				url: new URL('http://localhost/admin/login'),
				getClientAddress: () => ip,
				locals: ADMIN_TEST_LOCALS,
				fetch: durableSessionFetchMock()
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/admin/fleet'
		});

		// After successful login, rate limit counter should be reset —
		// a subsequent attempt should NOT be blocked
		const afterResult = checkAdminLoginRateLimit(ip);
		expect(afterResult.blocked).toBe(false);
	});

	it('ignores spoofed forwarding headers when rate limiting admin login', async () => {
		const blockedIp = '203.0.113.55';
		for (let i = 0; i < DEFAULT_ADMIN_LOGIN_MAX_ATTEMPTS; i++) {
			checkAdminLoginRateLimit(blockedIp);
		}

		const cookies = new MockCookies();
		const request = new Request('http://localhost/admin/login', {
			method: 'POST',
			headers: { 'x-forwarded-for': blockedIp },
			body: new URLSearchParams({ admin_key: 'wrong-key' })
		});

		const result = await loginActions.default({
			request,
			cookies,
			url: new URL('http://localhost/admin/login'),
			getClientAddress: () => '198.51.100.10',
			locals: ADMIN_TEST_LOCALS,
			fetch: durableSessionFetchMock()
		} as never);

		expect(result.status).toBe(401);
		expect(result.data.errors.form).toBe('Invalid admin key');
	});
});

describe('Admin session max age parsing', () => {
	it('accepts a strict positive integer value', () => {
		expect(resolveAdminSessionMaxAgeSeconds('7200')).toBe(7200);
	});

	it('falls back to default for values with trailing units', () => {
		expect(resolveAdminSessionMaxAgeSeconds('7200s')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});

	it('falls back to default for fractional values', () => {
		expect(resolveAdminSessionMaxAgeSeconds('60.5')).toBe(DEFAULT_ADMIN_SESSION_MAX_AGE_SECONDS);
	});
});

describe('Admin client', () => {
	it('sends X-Admin-Key header on all requests', async () => {
		let capturedHeaders: Headers | null = null;

		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-admin-key');
		client.setFetch(async (input: string | URL | Request, init?: RequestInit) => {
			capturedHeaders = new Headers(init?.headers);
			return new Response(JSON.stringify([]), { status: 200 });
		});

		await client.getFleet();

		expect(capturedHeaders!.get('X-Admin-Key')).toBe('test-admin-key');
		expect(capturedHeaders!.get('Content-Type')).toBe('application/json');
	});

	it('throws descriptive error on non-OK response', async () => {
		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(async () => {
			return new Response(JSON.stringify({ error: 'Forbidden' }), { status: 403 });
		});

		await expect(client.getTenants()).rejects.toThrow('Forbidden');
	});

	it('throws fallback error when response body is not JSON', async () => {
		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(async () => {
			return new Response('Internal Server Error', { status: 500 });
		});

		await expect(client.getFleet()).rejects.toThrow('Admin API request failed');
	});

	it('handles 204 No Content without parsing body', async () => {
		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(async () => {
			return new Response(null, { status: 204 });
		});

		const result = await client.getFleet();
		expect(result).toBeUndefined();
	});

	it('admin client factory accepts ADMIN_KEY from Cloudflare platform env', async () => {
		delete process.env.ADMIN_KEY;
		const { createAdminClient } = await import('$lib/admin-client');
		const client = createAdminClient('http://localhost:3000', { ADMIN_KEY: 'platform-admin-key' });
		const fetchSpy = vi.fn().mockResolvedValue(new Response(JSON.stringify([]), { status: 200 }));
		client.setFetch(fetchSpy);

		await client.getFleet();

		expect(fetchSpy).toHaveBeenCalledWith('http://localhost:3000/admin/fleet', {
			headers: {
				'Content-Type': 'application/json',
				'X-Admin-Key': 'platform-admin-key'
			}
		});
	});

	it('retries admin requests when the API responds with 429', async () => {
		const timeoutSpy = vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		) => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		const fetchSpy = vi
			.fn()
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ error: 'too many requests' }), {
					status: 429,
					headers: { 'Retry-After': '1' }
				})
			)
			.mockResolvedValueOnce(
				new Response(JSON.stringify([{ id: 'tenant-1', name: 'Retry Tenant' }]), { status: 200 })
			);

		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(fetchSpy);

		const result = await client.getTenants();

		expect(fetchSpy).toHaveBeenCalledTimes(2);
		expect(timeoutSpy).toHaveBeenCalled();
		expect(result).toEqual([{ id: 'tenant-1', name: 'Retry Tenant' }]);
		timeoutSpy.mockRestore();
	});

	it('constructs correct URL for getTenant', async () => {
		let capturedUrl = '';

		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000/', 'test-key');
		client.setFetch(async (input: string | URL | Request) => {
			capturedUrl = typeof input === 'string' ? input : input.toString();
			return new Response(JSON.stringify({ id: 'abc', name: 'Test' }), { status: 200 });
		});

		await client.getTenant('abc-123');

		// Should strip trailing slash from base URL and build correct path
		expect(capturedUrl).toBe('http://localhost:3000/admin/tenants/abc-123');
	});

	it('suspendCustomer calls POST /admin/customers/:id/suspend', async () => {
		let capturedUrl = '';
		let capturedMethod = '';

		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(async (input: string | URL | Request, init?: RequestInit) => {
			capturedUrl = typeof input === 'string' ? input : input.toString();
			capturedMethod = init?.method ?? 'GET';
			return new Response(JSON.stringify({ message: 'customer suspended' }), { status: 200 });
		});

		const result = await client.suspendCustomer('abc-123');

		expect(capturedUrl).toBe('http://localhost:3000/admin/customers/abc-123/suspend');
		expect(capturedMethod).toBe('POST');
		expect(result.message).toBe('customer suspended');
	});

	it('createToken calls POST /admin/tokens with the expected payload', async () => {
		let capturedUrl = '';
		let capturedMethod = '';
		let capturedBody = '';

		const { AdminClient } = await import('$lib/admin-client');
		const client = new AdminClient('http://localhost:3000', 'test-key');
		client.setFetch(async (input: string | URL | Request, init?: RequestInit) => {
			capturedUrl = typeof input === 'string' ? input : input.toString();
			capturedMethod = init?.method ?? 'GET';
			capturedBody = String(init?.body ?? '');
			return new Response(
				JSON.stringify({
					token: 'jwt-token',
					expires_at: '2026-03-23T12:00:00Z'
				}),
				{ status: 200 }
			);
		});

		const result = await client.createToken('abc-123', 3600);

		expect(capturedUrl).toBe('http://localhost:3000/admin/tokens');
		expect(capturedMethod).toBe('POST');
		expect(JSON.parse(capturedBody)).toEqual({
			customer_id: 'abc-123',
			expires_in_secs: 3600
		});
		expect(result).toEqual({
			token: 'jwt-token',
			expires_at: '2026-03-23T12:00:00Z'
		});
	});
});
