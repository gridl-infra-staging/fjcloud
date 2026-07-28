import { describe, expect, it } from 'vitest';
import { MARKETING_PRICING } from '$lib/pricing';

import * as rootPageServer from './+page.server';
import { load } from './+page.server';

type RootLoadEvent = Parameters<typeof load>[0];

function makeUnauthenticatedRootLoadEvent(): RootLoadEvent {
	return {
		url: new URL('http://localhost/'),
		locals: { user: null }
	} as unknown as RootLoadEvent;
}

describe('root page server load contract', () => {
	it('returns canonical marketing pricing for unauthenticated root requests', async () => {
		await expect(load(makeUnauthenticatedRootLoadEvent())).resolves.toEqual({
			pricing: MARKETING_PRICING
		});
	});

	it('pins root route to dynamic SSR so prerender build cannot drop /', () => {
		expect((rootPageServer as Record<string, unknown>).prerender).toBe(false);
	});
});
