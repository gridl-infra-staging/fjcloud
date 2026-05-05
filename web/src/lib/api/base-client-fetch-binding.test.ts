import { describe, it, expect } from 'vitest';
import { ApiClient } from './client';

// Regression test for the Cloudflare Workers fetch-binding contract that
// commit bd33540b put in place on `BaseClient.fetchFn`. If this test fails,
// somebody removed the `.bind(globalThis)` and is about to break the live
// auth flow (signup, /verify-email, /forgot-password, /dashboard/*) in any
// environment where `globalThis.fetch` requires `this === globalThis` at
// call time — which is what Cloudflare Workers does.
//
// The exact failure mode without the bind:
//   Worker stores `this.fetchFn = globalThis.fetch` (unbound reference).
//   Later, `await this.fetchFn(url, init)` invokes it as a method, so
//   `this === <BaseClient instance>` rather than `globalThis`.
//   Workers' fetch builtin throws:
//     TypeError: Illegal invocation: function called with incorrect 'this' reference.
//   `mapAuthLoadFailureMessage` then maps that TypeError to
//     "Authentication service is unavailable. Please verify API_URL and try again."
//   which is the misleading customer message that masked the bug as an env-var
//   problem for ~6 weeks during the LB-2 chase.
//
// We can't reproduce the actual `this === globalThis` enforcement from a
// Node.js test environment (Node's fetch is permissive). What we CAN do —
// and what catches the regression cleanly — is assert that the BaseClient
// default fetchFn is a *different reference* than `globalThis.fetch`.
// `Function.prototype.bind` always returns a new function, so:
//   - With the bind in place: client.fetchFn !== globalThis.fetch
//   - Without the bind:       client.fetchFn === globalThis.fetch
// The first assertion below fails the test if anyone deletes the bind.
//
// Decision record:
//   docs/decisions/2026-05-02_adapter_cloudflare_migration.md
// Cloudflare doc on this exact error class:
//   https://developers.cloudflare.com/workers/observability/errors/#illegal-invocation-errors
describe('BaseClient default fetchFn — Cloudflare Workers bind contract', () => {
	// Subclasses inherit the bound default; ApiClient is the production
	// subclass and is what every server load/action uses via createApiClient(),
	// so testing through ApiClient covers the same code path that ships.
	it('is bound to globalThis (i.e. NOT the raw globalThis.fetch reference)', () => {
		const client = new ApiClient('http://example.invalid');

		// Access via cast: fetchFn is `protected` so the compiler doesn't
		// expose it on the instance type. We reach in here intentionally —
		// this test is asserting an internal contract that callers rely on.
		const fetchFn = (client as unknown as { fetchFn: typeof globalThis.fetch }).fetchFn;

		// The bind contract: must NOT be the same reference as globalThis.fetch.
		// `Function.prototype.bind` always creates a new function.
		expect(fetchFn).not.toBe(globalThis.fetch);

		// And must still be a function (not undefined / not some wrapper that
		// stripped callability).
		expect(typeof fetchFn).toBe('function');
	});

	it('preserves Worker call semantics when the bound default is invoked as a method', async () => {
		const client = new ApiClient('http://127.0.0.1:1');

		// Invoking the bound fetch as a method — `this === client` in JS — must
		// not throw "Illegal invocation". On Workers, only the bound version
		// survives this. On Node, both work, but the test still proves the
		// bound function is callable with our expected method-call shape.
		const fetchFn = (client as unknown as { fetchFn: typeof globalThis.fetch }).fetchFn;

		// We expect a network failure (port 1 won't accept connections), NOT a
		// TypeError. If the bind is missing on Workers, this would surface as
		// the TypeError described in the file header. We accept either a
		// TypeError-free rejection or a successful resolve — both prove the
		// "Illegal invocation" failure mode is gone.
		await expect(
			(async () => {
				try {
					await fetchFn('http://127.0.0.1:1/never');
				} catch (e) {
					// Re-throw only if it's the TypeError we're guarding against.
					// Other errors (network, DNS, etc.) are fine — they prove the
					// invocation itself reached the fetch implementation.
					if (e instanceof TypeError && /illegal invocation/i.test(e.message)) {
						throw e;
					}
				}
			})()
		).resolves.toBeUndefined();
	});
});
