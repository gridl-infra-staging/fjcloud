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

import { GET as getRoot } from './+server';
import { GET as getCatchAll } from './[...path]/+server';

type GetRootEvent = Parameters<typeof getRoot>[0];
type GetCatchAllEvent = Parameters<typeof getCatchAll>[0];

function makeRequestEvent<E>(href: string): E {
	const url = new URL(href);
	return { url } as unknown as E;
}

function captureRedirect(fn: () => unknown): MockRedirect {
	try {
		fn();
	} catch (error) {
		if (error instanceof MockRedirect) {
			return error;
		}
		throw error;
	}
	throw new Error('Expected redirect to be thrown, but none was');
}

describe('legacy /dashboard redirect contract', () => {
	it('redirects /dashboard root to /console with 308 permanent', () => {
		const redirect = captureRedirect(() =>
			getRoot(makeRequestEvent<GetRootEvent>('http://localhost/dashboard'))
		);
		expect(redirect.status).toBe(308);
		expect(redirect.location).toBe('/console');
	});

	it('redirects /dashboard/indexes/products to /console/indexes/products with 308', () => {
		const redirect = captureRedirect(() =>
			getCatchAll(makeRequestEvent<GetCatchAllEvent>('http://localhost/dashboard/indexes/products'))
		);
		expect(redirect.status).toBe(308);
		expect(redirect.location).toBe('/console/indexes/products');
	});

	it('preserves multi-param query string when redirecting deep /dashboard paths to /console', () => {
		const redirect = captureRedirect(() =>
			getCatchAll(
				makeRequestEvent<GetCatchAllEvent>(
					'http://localhost/dashboard/billing/invoices/inv_123?from=email&view=history'
				)
			)
		);
		expect(redirect.status).toBe(308);
		expect(redirect.location).toBe('/console/billing/invoices/inv_123?from=email&view=history');
	});
});
