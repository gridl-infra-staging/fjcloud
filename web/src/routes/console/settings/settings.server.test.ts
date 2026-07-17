import { describe, expect, it } from 'vitest';

import { load } from './+page.server';

describe('Settings compatibility server seam', () => {
	it('does not redirect when rendering the settings compatibility wrapper', async () => {
		await expect(load({ locals: { user: { token: 'jwt-token' } } } as never)).resolves.toEqual({});
	});
});
