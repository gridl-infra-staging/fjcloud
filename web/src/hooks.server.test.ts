import { describe, it, expect, vi, beforeEach } from 'vitest';
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

vi.mock('$env/dynamic/private', () => ({
	env: { JWT_SECRET: 'test-secret' }
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

function makeEvent(pathname: string, token?: string): RequestEvent {
	const locals: Record<string, unknown> = {};
	const deleteCookie = vi.fn();
	return {
		cookies: {
			get: vi.fn((name: string) => (name === 'auth_token' ? token : undefined)),
			delete: deleteCookie
		},
		url: new URL(`http://localhost${pathname}`),
		locals
	} as unknown as RequestEvent;
}

async function callHandle(
	pathname: string,
	token?: string
): Promise<{ resolved: boolean; event: RequestEvent; response?: Response }> {
	const event = makeEvent(pathname, token);
	const resolve = vi.fn(async () => new Response('ok'));
	let resolved = false;
	let response: Response | undefined;
	try {
		response = await (handle as Handle)({ event, resolve } as never);
		resolved = true;
	} catch (e) {
		if (e instanceof MockRedirect) {
			return { resolved: false, event };
		}
		throw e;
	}
	return { resolved, event, response };
}

async function expectRedirect(
	pathname: string,
	token: string | undefined,
	expectedLocation: string
): Promise<void> {
	const event = makeEvent(pathname, token);
	const resolve = vi.fn(async () => new Response('ok'));
	try {
		await (handle as Handle)({ event, resolve } as never);
		expect.fail(`Expected redirect to ${expectedLocation}, but resolve() was called`);
	} catch (e) {
		expect(e).toBeInstanceOf(MockRedirect);
		expect((e as MockRedirect).status).toBe(303);
		expect((e as MockRedirect).location).toBe(expectedLocation);
	}
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
	});

	describe('isPublicPath logic', () => {
		it('treats / as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/', 'valid-jwt', '/dashboard');
		});

		it('treats /login as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/login', 'valid-jwt', '/dashboard');
		});

		it('treats /signup as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/signup', 'valid-jwt', '/dashboard');
		});

		it('treats /verify-email/some-token as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/verify-email/abc123', 'valid-jwt', '/dashboard');
		});

		it('treats /forgot-password as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/forgot-password', 'valid-jwt', '/dashboard');
		});

		it('treats /reset-password/tok as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/reset-password/tok', 'valid-jwt', '/dashboard');
		});

		it('does NOT treat /dashboard as public', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			const { resolved } = await callHandle('/dashboard', 'valid-jwt');
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

		it('redirects /dashboard to /login when not authenticated', async () => {
			resolveAuthMock.mockReturnValue(null);
			await expectRedirect('/dashboard', undefined, '/login');
		});

		it('redirects /dashboard/indexes to /login when not authenticated', async () => {
			resolveAuthMock.mockReturnValue(null);
			await expectRedirect('/dashboard/indexes', undefined, '/login');
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

		it('clears a stale auth cookie before redirecting dashboard traffic to /login', async () => {
			resolveAuthMock.mockReturnValue(null);
			const event = makeEvent('/dashboard', 'stale-jwt');
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
		it('redirects / to /dashboard when authenticated', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/', 'jwt', '/dashboard');
		});

		it('redirects /login to /dashboard when authenticated', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			await expectRedirect('/login', 'jwt', '/dashboard');
		});

		it('allows /dashboard when authenticated', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			const { resolved } = await callHandle('/dashboard', 'jwt');
			expect(resolved).toBe(true);
		});

		it('allows /dashboard/settings when authenticated', async () => {
			resolveAuthMock.mockReturnValue({ customerId: 'c1', token: 't' });
			const { resolved } = await callHandle('/dashboard/settings', 'jwt');
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

		it('sets locals.user from resolveAuth result', async () => {
			const user = { customerId: 'cust-42', token: 'jwt-tok' };
			resolveAuthMock.mockReturnValue(user);
			const { event } = await callHandle('/dashboard', 'jwt-tok');
			expect(event.locals.user).toEqual(user);
		});

		it('sets locals.user to null when resolveAuth returns null', async () => {
			resolveAuthMock.mockReturnValue(null);
			const { event } = await callHandle('/', undefined);
			expect(event.locals.user).toBeNull();
		});
	});
});

describe('hooks.server handleError', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('logs the customer support reference with the backend request id without raw internals', async () => {
		const consoleError = vi.spyOn(console, 'error').mockImplementation(() => undefined);
		const event = makeEvent('/dashboard/indexes');
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
			path: '/dashboard/indexes',
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
