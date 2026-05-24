import { describe, expect, it, vi } from 'vitest';

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

import * as rootPageServer from './+page.server';
import { load } from './+page.server';

type RootLoadEvent = Parameters<typeof load>[0];

function makeUnauthenticatedRootLoadEvent(): RootLoadEvent {
	return {
		url: new URL('http://localhost/'),
		locals: { user: null }
	} as unknown as RootLoadEvent;
}

async function captureRedirect(fn: () => unknown | Promise<unknown>): Promise<MockRedirect> {
	try {
		await fn();
	} catch (error) {
		if (error instanceof MockRedirect) {
			return error;
		}
		throw error;
	}
	throw new Error('Expected redirect to be thrown, but none was');
}

describe('root page server load contract', () => {
	it('redirects unauthenticated root requests to /login with 303', async () => {
		const thrown = await captureRedirect(() => load(makeUnauthenticatedRootLoadEvent()));
		expect(thrown.status).toBe(303);
		expect(thrown.location).toBe('/login');
	});

	it('pins root route to dynamic SSR so prerender build cannot drop /', () => {
		expect((rootPageServer as Record<string, unknown>).prerender).toBe(false);
	});
});
