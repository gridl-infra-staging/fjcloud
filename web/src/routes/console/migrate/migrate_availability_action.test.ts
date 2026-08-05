import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

vi.mock('$lib/server/api', async () => {
	const { createMigrationApiClientMock } = await import('./migrate_server_test_fixtures');
	return { createApiClient: vi.fn(createMigrationApiClientMock) };
});

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

import { actions } from './+page.server';
import {
	CLOSED_SOURCE_PROVIDERS,
	getAlgoliaMigrationAvailabilityMock,
	getMigrationAvailabilityMock,
	payloadRequest,
	resetMigrateServerMocks
} from './migrate_server_test_fixtures';

function invokeAvailability(request: unknown): unknown {
	const action = (actions as Record<string, (event: never) => unknown>).availability;
	return action({ request, locals: { user: { token: 'jwt-secret-canary' } } } as never);
}

describe('Migration availability action', () => {
	beforeEach(resetMigrateServerMocks);

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'forwards selected source_provider %s to the neutral API client method',
		async (sourceProvider) => {
			const result = await invokeAvailability(payloadRequest({ source_provider: sourceProvider }));

			expect(result).toEqual({
				availability: {
					available: false,
					reason: 'temporarily_unavailable',
					message: 'Algolia migration is temporarily unavailable while we replace the importer.',
					capabilities: {
						cancel: false,
						resume: false,
						replace: false,
						preview: false,
						verify: false
					}
				}
			});
			expect(getMigrationAvailabilityMock).toHaveBeenCalledOnce();
			expect(getMigrationAvailabilityMock).toHaveBeenCalledWith(sourceProvider);
			expect(getAlgoliaMigrationAvailabilityMock).not.toHaveBeenCalled();
		}
	);

	it('maps a session failure through the shared dashboard auth contract', async () => {
		getMigrationAvailabilityMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await invokeAvailability(payloadRequest({ source_provider: 'typesense' }));

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: { _authSessionExpired: true, error: 'Unauthorized' }
			})
		);
	});

	it('maps upstream failures through the migration action failure shape', async () => {
		getMigrationAvailabilityMock.mockRejectedValue(
			new ApiRequestError(503, 'upstream unavailable', {
				body: { detail: 'Migration availability is temporarily unavailable' }
			})
		);

		const result = await invokeAvailability(payloadRequest({ source_provider: 'meilisearch' }));

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: { error: 'Migration availability is temporarily unavailable' }
			})
		);
	});
});
