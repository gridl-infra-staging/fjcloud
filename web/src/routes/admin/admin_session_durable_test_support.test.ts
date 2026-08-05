/**
 * Tests for the shared durable-admin-session test support module itself.
 *
 * `withDurableAdminSession` is consumed by every admin route test, so a defect
 * in it makes unrelated route suites lie rather than fail. Its own coverage
 * therefore lives beside it rather than inside whichever route test happened to
 * need it first.
 */
import { describe, expect, it, vi } from 'vitest';
import {
	ADMIN_TEST_API_BASE_URL,
	DURABLE_SESSION_OPERATOR_ID,
	OPAQUE_DURABLE_SESSION_TOKEN,
	withDurableAdminSession
} from './admin_session_durable_test_support';

describe('withDurableAdminSession', () => {
	it('only intercepts the configured admin API origin', async () => {
		const routeFetch = vi.fn(async () => new Response('passthrough', { status: 418 }));
		const fetch = withDurableAdminSession(routeFetch, 'active');
		const headers = new Headers({ 'x-admin-session': OPAQUE_DURABLE_SESSION_TOKEN });

		// A same-path request to a foreign origin must fall through to the route's
		// own stub, not be answered by the session mock — otherwise a route test
		// that talks to an unexpected host silently "authenticates".
		const wrongOrigin = await fetch(
			new Request('https://evil.test/admin/sessions/current', { method: 'GET', headers })
		);
		expect(routeFetch).toHaveBeenCalledOnce();
		expect(wrongOrigin.status).toBe(418);

		const rightOrigin = await fetch(
			new Request(`${ADMIN_TEST_API_BASE_URL}/admin/sessions/current`, { method: 'GET', headers })
		);
		expect(await rightOrigin.json()).toEqual({ operator_id: DURABLE_SESSION_OPERATOR_ID });
	});
});
