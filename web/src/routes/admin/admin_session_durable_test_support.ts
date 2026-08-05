import { vi } from 'vitest';
import { ADMIN_SESSION_COOKIE } from '$lib/server/admin-session';

export const OPAQUE_DURABLE_SESSION_TOKEN =
	'018fe4e2-4d51-7c2a-9c90-6f239bfe8b41.opaque-session-secret-from-api';
export const DURABLE_SESSION_OPERATOR_ID = '018fe4e2-4d51-7c2a-9c90-6f239bfe8b42';
export const REQUESTED_SESSION_MAX_AGE_SECONDS = 60 * 60 * 8;
/** The only credential the mocked API resolves to an operator. */
export const REGISTERED_ADMIN_KEY = 'top-secret-admin-key';
export const ADMIN_TEST_API_BASE_URL = 'https://api.test';
export const ADMIN_TEST_LOCALS = { apiBaseUrl: ADMIN_TEST_API_BASE_URL };

export type CookieOptions = {
	path?: string;
	httpOnly?: boolean;
	secure?: boolean;
	sameSite?: 'lax' | 'strict' | 'none';
	maxAge?: number;
};

export class MockCookies {
	private readonly store = new Map<string, string>();
	readonly setCalls: Array<{ name: string; value: string; options: CookieOptions }> = [];
	readonly deleteCalls: Array<{ name: string; options: CookieOptions }> = [];

	constructor(
		initial: Record<string, string> = {},
		private readonly operationLog: string[] = []
	) {
		for (const [name, value] of Object.entries(initial)) {
			this.store.set(name, value);
		}
	}

	get(name: string): string | undefined {
		return this.store.get(name);
	}

	set(name: string, value: string, options: CookieOptions): void {
		this.store.set(name, value);
		this.setCalls.push({ name, value, options });
	}

	delete(name: string, options: CookieOptions): void {
		this.store.delete(name);
		this.deleteCalls.push({ name, options });
		this.operationLog.push('cookie-delete');
	}
}

/** Cookie jar carrying a live durable admin session. */
export function authenticatedAdminCookies(): MockCookies {
	return new MockCookies({ [ADMIN_SESSION_COOKIE]: OPAQUE_DURABLE_SESSION_TOKEN });
}

type RouteFetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

function toRequest(input: RequestInfo | URL, init?: RequestInit): Request {
	return input instanceof Request ? input : new Request(input, init);
}

function isAdminApiRequest(endpoint: URL, pathname: '/admin/sessions' | '/admin/sessions/current') {
	return endpoint.origin === ADMIN_TEST_API_BASE_URL && endpoint.pathname === pathname;
}

/**
 * Focused stand-in for the durable admin-session endpoints owned by
 * `infra/api/src/routes/admin/sessions.rs`. Response shapes are kept in exact
 * agreement with the real handlers: `POST /admin/sessions` returns only
 * `{ session_id }`, `GET /admin/sessions/current` returns only
 * `{ operator_id }`, and revocation returns 204 with no body.
 */
export class DurableAdminSessionApi {
	private state: 'active' | 'revoked' | 'missing' = 'active';
	private createUnavailable = false;

	constructor(private readonly operationLog: string[] = []) {}

	readonly fetch = vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
		const request = toRequest(input, init);
		const endpoint = new URL(request.url);

		if (request.method === 'POST' && isAdminApiRequest(endpoint, '/admin/sessions')) {
			this.operationLog.push('api-create');
			if (this.createUnavailable) {
				return Response.json({ error: 'internal error' }, { status: 500 });
			}
			if (request.headers.get('x-admin-key') !== REGISTERED_ADMIN_KEY) {
				return Response.json({ error: 'invalid admin key' }, { status: 401 });
			}
			return Response.json({ session_id: OPAQUE_DURABLE_SESSION_TOKEN });
		}

		const hasActiveSession =
			this.state === 'active' &&
			request.headers.get('x-admin-session') === OPAQUE_DURABLE_SESSION_TOKEN;

		if (request.method === 'DELETE' && isAdminApiRequest(endpoint, '/admin/sessions')) {
			this.operationLog.push('api-revoke-all');
			if (!hasActiveSession) return new Response(null, { status: 401 });
			this.state = 'revoked';
			return new Response(null, { status: 204 });
		}

		if (!isAdminApiRequest(endpoint, '/admin/sessions/current')) {
			throw new Error(`unexpected durable admin session request: ${request.method} ${request.url}`);
		}

		if (request.method === 'GET') {
			this.operationLog.push('api-validate');
			return hasActiveSession
				? Response.json({ operator_id: DURABLE_SESSION_OPERATOR_ID })
				: new Response(null, { status: 401 });
		}
		if (request.method === 'DELETE') {
			this.operationLog.push('api-revoke');
			if (!hasActiveSession) return new Response(null, { status: 401 });
			this.state = 'revoked';
			return new Response(null, { status: 204 });
		}

		throw new Error(`unexpected durable admin session request method: ${request.method}`);
	});

	revokeSession(): void {
		this.state = 'revoked';
	}

	removeSession(): void {
		this.state = 'missing';
	}

	/** Makes session minting fail with a server error instead of a credential rejection. */
	failCreateWithServerError(): void {
		this.createUnavailable = true;
	}
}

export function durableSessionFetchMock() {
	return new DurableAdminSessionApi().fetch;
}

/**
 * Wraps a route test's load/action argument so the shared durable-session guard
 * resolves: supplies the session cookie and API origin, and routes session
 * validation to the durable mock while leaving the test's own `fetch` stub in
 * charge of every other request. Pass `'revoked'` to exercise the redirect arm.
 */
export function adminSessionRouteEvent<T extends { fetch: unknown }>(
	event: T,
	sessionState: 'active' | 'revoked' = 'active'
) {
	return {
		cookies: sessionState === 'active' ? authenticatedAdminCookies() : new MockCookies(),
		locals: ADMIN_TEST_LOCALS,
		...event,
		fetch: withDurableAdminSession(event.fetch as RouteFetch, sessionState)
	};
}

/**
 * `adminSessionRouteEvent` cast to the shape SvelteKit's generated `load`/action
 * types demand. Route tests supply only the fields the handler under test reads,
 * so the cast is the seam that keeps them from having to model a whole
 * `RequestEvent`. Kept here rather than in each route's test file so the cast has
 * one owner.
 */
export function authenticatedRouteLoadContext(
	overrides: {
		fetch: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
	} & Record<string, unknown>
) {
	return adminSessionRouteEvent(overrides) as never;
}

/**
 * Wraps a route test's own `fetch` stub so the shared durable-session guard
 * resolves without every admin route fixture having to model session
 * validation itself. Only `GET /admin/sessions/current` is intercepted; every
 * other request falls through to the route's stub unchanged.
 */
export function withDurableAdminSession(
	routeFetch: RouteFetch,
	sessionState: 'active' | 'revoked' = 'active'
): typeof globalThis.fetch {
	return (async (input: RequestInfo | URL, init?: RequestInit) => {
		const request = toRequest(input, init);
		const endpoint = new URL(request.url);
		const isSessionValidation =
			request.method === 'GET' && isAdminApiRequest(endpoint, '/admin/sessions/current');
		if (!isSessionValidation) {
			return routeFetch(input, init);
		}
		const authenticated =
			sessionState === 'active' &&
			request.headers.get('x-admin-session') === OPAQUE_DURABLE_SESSION_TOKEN;
		return authenticated
			? Response.json({ operator_id: DURABLE_SESSION_OPERATOR_ID })
			: new Response(null, { status: 401 });
	}) as typeof globalThis.fetch;
}
