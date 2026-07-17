import { describe, expect, it, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

import { AUTH_COOKIE, IMPERSONATION_COOKIE } from '$lib/config';

type CookieOptions = {
	path?: string;
	httpOnly?: boolean;
	secure?: boolean;
	sameSite?: 'lax' | 'strict' | 'none';
	maxAge?: number;
};

class MockCookies {
	private store = new Map<string, string>();
	readonly deleteCalls: Array<{ name: string; options: CookieOptions }> = [];

	constructor(initial: Record<string, string> = {}) {
		for (const [name, value] of Object.entries(initial)) {
			this.store.set(name, value);
		}
	}

	get(name: string): string | undefined {
		return this.store.get(name);
	}

	delete(name: string, options: CookieOptions): void {
		this.store.delete(name);
		this.deleteCalls.push({ name, options });
	}
}

async function expectPostRedirect(cookies: MockCookies, expectedLocation: string) {
	const { POST } = await import('./+server');

	try {
		await POST({
			cookies,
			request: new Request('http://localhost/admin/end-impersonation', { method: 'POST' })
		} as never);
		expect.unreachable('Expected redirect to be thrown');
	} catch (e: unknown) {
		const err = e as { status: number; location: string };
		expect(err.status).toBe(303);
		expect(err.location).toBe(expectedLocation);
	}
}

describe('End impersonation POST handler', () => {
	it('deletes both cookies and redirects to the impersonation return path', async () => {
		const returnPath = '/admin/customers/aaaaaaaa-0002-0000-0000-000000000002';
		const cookies = new MockCookies({
			[AUTH_COOKIE]: 'jwt-token-abc',
			[IMPERSONATION_COOKIE]: returnPath
		});

		await expectPostRedirect(cookies, returnPath);

		// Both cookies deleted with path '/'
		expect(cookies.deleteCalls).toHaveLength(2);
		const authDelete = cookies.deleteCalls.find((c) => c.name === AUTH_COOKIE);
		const impDelete = cookies.deleteCalls.find((c) => c.name === IMPERSONATION_COOKIE);
		expect(authDelete).toBeDefined();
		expect(authDelete!.options.path).toBe('/');
		expect(impDelete).toBeDefined();
		expect(impDelete!.options.path).toBe('/');
	});

	it('falls back to /admin/fleet when impersonation cookie is missing', async () => {
		const cookies = new MockCookies({
			[AUTH_COOKIE]: 'jwt-token-abc'
		});

		await expectPostRedirect(cookies, '/admin/fleet');
	});

	it('falls back to /admin/fleet when return path is tampered (non-admin path)', async () => {
		const cookies = new MockCookies({
			[AUTH_COOKIE]: 'jwt-token-abc',
			[IMPERSONATION_COOKIE]: 'https://evil.com/steal'
		});

		await expectPostRedirect(cookies, '/admin/fleet');
	});

	it('falls back to /admin/fleet when return path is protocol-relative', async () => {
		const cookies = new MockCookies({
			[AUTH_COOKIE]: 'jwt-token-abc',
			[IMPERSONATION_COOKIE]: '//evil.com/admin'
		});

		await expectPostRedirect(cookies, '/admin/fleet');
	});

	it('falls back to /admin/fleet when return path only shares the /admin prefix', async () => {
		const cookies = new MockCookies({
			[AUTH_COOKIE]: 'jwt-token-abc',
			[IMPERSONATION_COOKIE]: '/administrator'
		});

		await expectPostRedirect(cookies, '/admin/fleet');
	});

	it('falls back to /admin/fleet when return path escapes /admin via dot segments', async () => {
		const cookies = new MockCookies({
			[AUTH_COOKIE]: 'jwt-token-abc',
			[IMPERSONATION_COOKIE]: '/admin/../dashboard'
		});

		await expectPostRedirect(cookies, '/admin/fleet');
	});

	it('falls back to /admin/fleet when return path uses encoded dot segments', async () => {
		const cookies = new MockCookies({
			[AUTH_COOKIE]: 'jwt-token-abc',
			[IMPERSONATION_COOKIE]: '/admin/%2e%2e/dashboard'
		});

		await expectPostRedirect(cookies, '/admin/fleet');
	});
});
