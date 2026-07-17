import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const getAlgoliaMigrationAvailabilityMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getAlgoliaMigrationAvailability: getAlgoliaMigrationAvailabilityMock
	}))
}));

import { load } from './+page.server';

describe('Migrate page server', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		getAlgoliaMigrationAvailabilityMock.mockResolvedValue({
			available: false,
			reason: 'temporarily_unavailable',
			message: 'Algolia migration is temporarily unavailable while we replace the importer.'
		});
	});

	it('load fetches authenticated migration availability from the shared API client', async () => {
		const result = await load({
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(getAlgoliaMigrationAvailabilityMock).toHaveBeenCalledOnce();
		expect(result).toEqual({
			availability: {
				available: false,
				reason: 'temporarily_unavailable',
				message: 'Algolia migration is temporarily unavailable while we replace the importer.'
			}
		});
	});

	it('load maps session failures through the dashboard auth contract', async () => {
		getAlgoliaMigrationAvailabilityMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await load({
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Unauthorized'
				})
			})
		);
	});

	it('does not export form actions for the unavailable migration page', async () => {
		const pageServer = await import('./+page.server');

		expect(pageServer).not.toHaveProperty('actions');
	});
});
