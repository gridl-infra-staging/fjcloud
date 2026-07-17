import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type { RequestEvent, Handle } from '@sveltejs/kit';
import { ApiRequestError } from '$lib/api/client';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROBOTS_TAG = 'noindex, nofollow, noarchive, nosnippet, noimageindex, noai, noimageai';

// --- Mocks ---

const resolveAuthMock = vi.fn();
vi.mock('$lib/auth/guard', () => ({
	resolveAuth: (...args: unknown[]) => resolveAuthMock(...args)
}));

// Proxy onto process.env so tests can drop JWT_SECRET from the static env and
// exercise the Cloudflare platform.env fallback (same pattern as admin/* tests).
vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

// SvelteKit's redirect() throws a Redirect object — mock it
class MockRedirect {
	constructor(
		public status: number,
		public location: string
	) {}
}
vi.mock('@sveltejs/kit', async () => {
	const actual = await vi.importActual<typeof import('@sveltejs/kit')>('@sveltejs/kit');
	return {
		...actual,
		redirect: (status: number, location: string) => {
			throw new MockRedirect(status, location);
		}
	};
});

import { handle, handleError } from './hooks.server';

// --- Helpers ---

function makeEvent(
	pathname: string,
	token?: string,
	platform?: { env: Record<string, string> }
): RequestEvent {
	const locals: Record<string, unknown> = {};
	const deleteCookie = vi.fn();
	const url = new URL(`http://localhost${pathname}`);
	return {
		cookies: {
			get: vi.fn((name: string) => (name === 'auth_token' ? token : undefined)),
			delete: deleteCookie
		},
		request: new Request(url.toString(), { headers: new Headers() }),
		url,
		locals,
		platform
	} as unknown as RequestEvent;
}

async function callHandle(
	pathname: string,
	token?: string,
	resolveImpl?: (event: RequestEvent) => Promise<Response>
): Promise<{
	resolved: boolean;
	event: RequestEvent;
	response?: Response;
	resolveSpy: ReturnType<typeof vi.fn>;
}> {
	const event = makeEvent(pathname, token);
	const resolve = vi.fn(resolveImpl ?? (async () => new Response('ok')));
	let resolved = false;
	let response: Response | undefined;
	try {
		response = await (handle as Handle)({ event, resolve } as never);
		resolved = true;
	} catch (e) {
		if (e instanceof MockRedirect) {
			return { resolved: false, event, resolveSpy: resolve };
		}
		throw e;
	}
	return { resolved, event, response, resolveSpy: resolve };
}

type RedirectCapture = {
	status: number;
	location: string;
	source: 'handle' | 'resolve';
};

async function captureRedirect(
	pathname: string,
	token: string | undefined,
	resolveImpl?: (event: RequestEvent) => Promise<Response>
): Promise<RedirectCapture> {
	const event = makeEvent(pathname, token);
	const resolve = vi.fn(resolveImpl ?? (async () => new Response('ok')));
	let caughtRedirect: unknown;
	try {
		await (handle as Handle)({ event, resolve } as never);
	} catch (e) {
		caughtRedirect = e;
	}
	expect(
		caughtRedirect,
		`Expected redirect for ${pathname}, but resolve() was called`
	).toBeDefined();
	expect(caughtRedirect).toBeInstanceOf(MockRedirect);
	return {
		status: (caughtRedirect as MockRedirect).status,
		location: (caughtRedirect as MockRedirect).location,
		source: resolve.mock.calls.length > 0 ? 'resolve' : 'handle'
	};
}

async function expectRedirect(
	pathname: string,
	token: string | undefined,
	expectedStatus: number,
	expectedLocation: string,
	resolveImpl?: (event: RequestEvent) => Promise<Response>
): Promise<void> {
	const redirectResult = await captureRedirect(pathname, token, resolveImpl);
	expect(redirectResult.status).toBe(expectedStatus);
	expect(redirectResult.location).toBe(expectedLocation);
}

function readCloudflareRobotsHeaderLine(): string {
	const testDir = dirname(fileURLToPath(import.meta.url));
	const headersPath = resolve(testDir, '..', '_headers');
	const firstTwoLines = readFileSync(headersPath, 'utf8').split(/\r?\n/).slice(0, 2);
	const robotsHeaderLine = firstTwoLines.find((line) => line.includes('X-Robots-Tag:'));
	if (!robotsHeaderLine) {
		throw new Error('web/_headers must define X-Robots-Tag on lines 1-2');
	}
	return robotsHeaderLine;
}

// --- Tests ---

describe('hooks.server handle', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		process.env.JWT_SECRET = 'test-secret';
	});

	afterEach(() => {
		delete process.env.JWT_SECRET;
	});

	describe('isPublicPath logic', () => {
		it('treats / as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/', 'valid-jwt', 303, '/console');
		});

		it('treats /login as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/login', 'valid-jwt', 303, '/console');
		});

		it('treats /signup as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/signup', 'valid-jwt', 303, '/console');
		});

		it('treats /verify-email/some-token as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/verify-email/abc123', 'valid-jwt', 303, '/console');
		});

		it('treats /forgot-password as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/forgot-password', 'valid-jwt', 303, '/console');
		});

		it('treats /reset-password/tok as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/reset-password/tok', 'valid-jwt', 303, '/console');
		});

		it('does NOT treat /console as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			const { resolved } = await callHandle('/console', 'valid-jwt');
			expect(resolved).toBe(true);
		});

		it('does NOT treat /admin as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			const { resolved } = await callHandle('/admin', 'valid-jwt');
			expect(resolved).toBe(true);
		});

		it('does NOT treat /loginx as public (no prefix match without /)', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			const { resolved } = await callHandle('/loginx', 'valid-jwt');
			expect(resolved).toBe(true);
		});
	});

	describe('unauthenticated access', () => {
		it('adds a robots header that blocks indexing while still allowing the page to be fetched', async () => {
			resolveAuthMock.mockReturnValue(null);

			const { response } = await callHandle('/', undefined);

			expect(response?.headers.get('X-Robots-Tag')).toBe(ROBOTS_TAG);
			expect(readCloudflareRobotsHeaderLine()).toBe(`  X-Robots-Tag: ${ROBOTS_TAG}`);
		});

		it('redirects /console to /login when not authenticated', async () => {
			resolveAuthMock.mockReturnValue(null);
			await expectRedirect('/console', undefined, 303, '/login');
		});

		it('redirects /console/indexes to /login when not authenticated', async () => {
			resolveAuthMock.mockReturnValue(null);
			await expectRedirect('/console/indexes', undefined, 303, '/login');
		});

		it('allows /login when not authenticated', async () => {
			resolveAuthMock.mockReturnValue(null);
			const { resolved } = await callHandle('/login', undefined);
			expect(resolved).toBe(true);
		});

		it('allows / when not authenticated', async () => {
			resolveAuthMock.mockReturnValue(null);
			const { resolved } = await callHandle('/', undefined);
			expect(resolved).toBe(true);
		});

		it('does not redirect unauthenticated /auth/oauth/google/callback requests', async () => {
			resolveAuthMock.mockReturnValue(null);
			const { resolved, response, resolveSpy } = await callHandle(
				'/auth/oauth/google/callback?code=dummy&state=dummy',
				undefined
			);
			expect(resolved).toBe(true);
			expect(resolveSpy).toHaveBeenCalledTimes(1);
			expect(response?.headers.get('X-Robots-Tag')).toBe(ROBOTS_TAG);
		});

		it('does not redirect unauthenticated /auth/oauth/github/callback requests', async () => {
			resolveAuthMock.mockReturnValue(null);
			const { resolved, response, resolveSpy } = await callHandle(
				'/auth/oauth/github/callback?code=dummy&state=dummy',
				undefined
			);
			expect(resolved).toBe(true);
			expect(resolveSpy).toHaveBeenCalledTimes(1);
			expect(response?.headers.get('X-Robots-Tag')).toBe(ROBOTS_TAG);
		});

		it('clears a stale auth cookie before redirecting dashboard traffic to /login', async () => {
			resolveAuthMock.mockReturnValue(null);
			const event = makeEvent('/console', 'stale-jwt');
			const resolve = vi.fn(async () => new Response('ok'));

			try {
				await (handle as Handle)({ event, resolve } as never);
				expect.fail('Expected redirect to /login');
			} catch (e) {
				expect(e).toBeInstanceOf(MockRedirect);
				expect((e as MockRedirect).location).toBe('/login');
			}

			expect(event.cookies.delete).toHaveBeenCalledWith('auth_token', { path: '/' });
		});
	});

	describe('authenticated access', () => {
		it('redirects / to /console when authenticated', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/', 'jwt', 303, '/console');
		});

		it('redirects /login to /console when authenticated', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/login', 'jwt', 303, '/console');
		});

		it('allows /console when authenticated', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			const { resolved, event } = await callHandle('/console', 'jwt');
			expect(resolved).toBe(true);
			expect(event.cookies.delete).not.toHaveBeenCalled();
		});

		it('allows /console/settings when authenticated', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			const { resolved } = await callHandle('/console/settings', 'jwt');
			expect(resolved).toBe(true);
		});

		it('treats /login?reason=session_expired as a forced reauth path', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			const event = makeEvent('/login?reason=session_expired', 'jwt');
			const resolve = vi.fn(async () => new Response('ok'));

			await (handle as Handle)({ event, resolve } as never);

			expect(resolve).toHaveBeenCalledTimes(1);
			expect(event.locals.user).toBeNull();
			expect(event.cookies.delete).toHaveBeenCalledWith('auth_token', { path: '/' });
		});
	});

	describe('resolveAuth integration', () => {
		it('passes cookie value and JWT_SECRET to resolveAuth', async () => {
			resolveAuthMock.mockReturnValue(null);
			await callHandle('/some-page', 'my-token');
			expect(resolveAuthMock).toHaveBeenCalledWith('my-token', 'test-secret');
		});

		it('resolves JWT_SECRET from Cloudflare platform env when the static env is absent', async () => {
			// On deployed Cloudflare Pages JWT_SECRET arrives via platform.env, not
			// $env/dynamic/private. Without the runtime-env fallback the /console
			// request that customer login lands on cannot authenticate the cookie,
			// so the user bounces back to /login.
			delete process.env.JWT_SECRET;
			resolveAuthMock.mockReturnValue(null);
			const event = makeEvent('/some-page', 'my-token', {
				env: { JWT_SECRET: 'platform-secret' }
			});
			const resolve = vi.fn(async () => new Response('ok'));

			await (handle as Handle)({ event, resolve } as never);

			expect(resolveAuthMock).toHaveBeenCalledWith('my-token', 'platform-secret');
		});

		it('sets locals.user from resolveAuth result', async () => {
			const user = { customerId: 'cust-42', token: 'jwt-tok' };
			resolveAuthMock.mockReturnValue(user);
			const { event } = await callHandle('/console', 'jwt-tok');
			expect(event.locals.user).toEqual(user);
		});

		it('sets locals.user to null when resolveAuth returns null', async () => {
			resolveAuthMock.mockReturnValue(null);
			const { event } = await callHandle('/', undefined);
			expect(event.locals.user).toBeNull();
		});

		it('derives api base URL from x-forwarded-host when custom domain hostname is not on event.url', async () => {
			resolveAuthMock.mockReturnValue(null);
			const event = makeEvent('/', undefined);
			const forwardedHeaders = new Headers({ 'x-forwarded-host': 'cloud.staging.flapjack.foo' });
			(event as unknown as { request: Request }).request = new Request(
				'https://flapjack-cloud.pages.dev/',
				{ headers: forwardedHeaders }
			);
			const resolve = vi.fn(async () => new Response('ok'));

			await (handle as Handle)({ event, resolve } as never);

			expect(event.locals.apiBaseUrl).toBe('https://api.staging.flapjack.foo');
		});
	});
});

describe('hooks.server handleError', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('logs the customer support reference with the backend request id without raw internals', async () => {
		const consoleError = vi.spyOn(console, 'error').mockImplementation(() => undefined);
		const event = makeEvent('/console/indexes');
		const error = new ApiRequestError(
			500,
			'PG::ConnectionBad: could not connect to 10.0.0.12:5432',
			{
				requestId: 'req-backend-123',
				headers: new Headers({ 'x-request-id': 'req-backend-123' })
			}
		);

		const result = (await handleError({
			error,
			event,
			status: 500,
			message: 'Internal server error'
		} as never)) as App.Error;

		expect(result.message).toBe('Internal server error');
		expect(result.supportReference).toMatch(/^web-[a-f0-9]{12}$/);
		expect(result.backendRequestId).toBe('req-backend-123');
		expect(result.supportReference).not.toBe(result.backendRequestId);
		expect(consoleError).toHaveBeenCalledTimes(1);
		const [eventName, report] = consoleError.mock.calls[0] as [string, Record<string, unknown>];
		expect(eventName).toBe('route error reported');
		expect(report).toEqual({
			path: '/console/indexes',
			status: 500,
			scope: 'dashboard',
			support_reference: result.supportReference,
			backend_request_id: 'req-backend-123'
		});
		expect(JSON.stringify(consoleError.mock.calls)).not.toContain('PG::ConnectionBad');
		expect(JSON.stringify(consoleError.mock.calls)).not.toContain('10.0.0.12');

		consoleError.mockRestore();
	});

	it('logs the web support reference without claiming backend correlation when no request id exists', async () => {
		const consoleError = vi.spyOn(console, 'error').mockImplementation(() => undefined);
		const event = makeEvent('/broken');

		const result = (await handleError({
			error: new Error('Traceback: ECONNREFUSED postgres.internal:5432'),
			event,
			status: 500,
			message: 'Internal server error'
		} as never)) as App.Error;

		const report = consoleError.mock.calls[0]?.[1] as Record<string, unknown>;
		expect(result.supportReference).toMatch(/^web-[a-f0-9]{12}$/);
		expect(result.backendRequestId).toBeUndefined();
		expect(consoleError).toHaveBeenCalledTimes(1);
		expect(report).toEqual({
			path: '/broken',
			status: 500,
			scope: 'public',
			support_reference: result.supportReference
		});
		expect(report).not.toHaveProperty('backend_request_id');
		expect(JSON.stringify(consoleError.mock.calls)).not.toContain('Traceback');
		expect(JSON.stringify(consoleError.mock.calls)).not.toContain('postgres.internal');

		consoleError.mockRestore();
	});
});
