import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import type { AlgoliaDestinationEligibilityRequest } from '$lib/api/types';
vi.mock('$lib/server/api', async () => {
	const { createMigrationApiClientMock } = await import('./migrate_server_test_fixtures');
	return { createApiClient: vi.fn(createMigrationApiClientMock) };
});

import { actions, load } from './+page.server';
import {
	CLOSED_SOURCE_PROVIDERS,
	INVALID_SOURCE_PROVIDERS,
	actionRequest,
	checkAlgoliaDestinationEligibilityMock,
	checkMigrationDestinationEligibilityMock,
	getAlgoliaMigrationAvailabilityMock,
	getMigrationAvailabilityMock,
	listAlgoliaImportJobsMock,
	listMigrationImportJobsMock,
	payloadRequest,
	resetMigrateServerMocks
} from './migrate_server_test_fixtures';

describe('Migrate page server', () => {
	beforeEach(resetMigrateServerMocks);

	it('load fetches default Algolia availability through the neutral API client owner', async () => {
		const result = await load({
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(getMigrationAvailabilityMock).toHaveBeenCalledWith('algolia');
		expect(getAlgoliaMigrationAvailabilityMock).not.toHaveBeenCalled();
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
			},
			recentImports: { page: null, error: null }
		});
	});

	it('does not fetch the recent-import list while migration is unavailable', async () => {
		await load({ locals: { user: { token: 'jwt' } } } as never);

		expect(listMigrationImportJobsMock).not.toHaveBeenCalled();
		expect(listAlgoliaImportJobsMock).not.toHaveBeenCalled();
	});

	it('fetches the initial recent-import page only after availability is true', async () => {
		getMigrationAvailabilityMock.mockResolvedValue({
			available: true,
			message: 'Algolia migration is available.',
			capabilities: { cancel: true, resume: false, replace: true, preview: true }
		});
		listMigrationImportJobsMock.mockResolvedValue({
			jobs: [{ id: 'job_123' }],
			nextCursor: 'cursor_2'
		});

		const result = (await load({
			locals: { user: { token: 'jwt' } }
		} as never)) as Record<string, unknown>;

		expect(listMigrationImportJobsMock).toHaveBeenCalledWith('algolia', { limit: 10 });
		expect(listAlgoliaImportJobsMock).not.toHaveBeenCalled();
		expect(result.recentImports).toEqual({
			page: { jobs: [{ id: 'job_123' }], nextCursor: 'cursor_2' },
			error: null
		});
	});

	it('converts an initial recent-import failure into a retryable list error without blocking availability', async () => {
		getMigrationAvailabilityMock.mockResolvedValue({
			available: true,
			message: 'Algolia migration is available.',
			capabilities: { cancel: true, resume: false, replace: true, preview: true }
		});
		listMigrationImportJobsMock.mockRejectedValue(new ApiRequestError(500, 'boom'));

		const result = (await load({
			locals: { user: { token: 'jwt-secret-canary' } }
		} as never)) as Record<string, unknown>;

		expect((result.availability as { available: boolean }).available).toBe(true);
		const recentImports = result.recentImports as { page: unknown; error: string };
		expect(recentImports.page).toBeNull();
		expect(typeof recentImports.error).toBe('string');
		expect(recentImports.error.length).toBeGreaterThan(0);
		expect(JSON.stringify(result)).not.toContain('jwt-secret-canary');
	});

	it('maps a 401 recent-import load failure through the dashboard auth contract', async () => {
		getMigrationAvailabilityMock.mockResolvedValue({
			available: true,
			message: 'Algolia migration is available.',
			capabilities: { cancel: true, resume: false, replace: true, preview: true }
		});
		listMigrationImportJobsMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

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

	it('recentImports action parses only provider, cursor, and limit and forwards pagination to the neutral API owner', async () => {
		listMigrationImportJobsMock.mockResolvedValue({
			jobs: [{ id: 'job_123' }],
			nextCursor: 'cursor_3'
		});

		const result = await actions.recentImports({
			request: actionRequest({
				source_provider: 'algolia',
				cursor: 'cursor_2',
				limit: '10',
				appId: 'algolia_app_id_canary',
				apiKey: 'algolia_api_key_canary'
			}),
			locals: { user: { token: 'jwt-secret-canary' } }
		} as never);

		expect(listMigrationImportJobsMock).toHaveBeenCalledOnce();
		expect(listMigrationImportJobsMock).toHaveBeenCalledWith('algolia', {
			cursor: 'cursor_2',
			limit: 10
		});
		expect(result).toEqual({
			recentImports: { jobs: [{ id: 'job_123' }], nextCursor: 'cursor_3' }
		});
		const serialized = JSON.stringify(result);
		expect(serialized).not.toContain('jwt-secret-canary');
		expect(serialized).not.toContain('algolia_app_id_canary');
		expect(serialized).not.toContain('algolia_api_key_canary');
	});

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'recentImports forwards selected source_provider %s and exact pagination to the neutral API client method',
		async (sourceProvider) => {
			listMigrationImportJobsMock.mockResolvedValue({
				jobs: [{ id: `${sourceProvider}-job`, sourceProvider }],
				nextCursor: `${sourceProvider}-cursor-3`
			});

			const result = await actions.recentImports({
				request: actionRequest({
					source_provider: sourceProvider,
					cursor: `${sourceProvider}-cursor-2`,
					limit: '10'
				}),
				locals: { user: { token: 'jwt-secret-canary' } }
			} as never);

			expect(listMigrationImportJobsMock).toHaveBeenCalledOnce();
			expect(listMigrationImportJobsMock).toHaveBeenCalledWith(sourceProvider, {
				cursor: `${sourceProvider}-cursor-2`,
				limit: 10
			});
			expect(listAlgoliaImportJobsMock).not.toHaveBeenCalled();
			expect(result).toEqual({
				recentImports: {
					jobs: [{ id: `${sourceProvider}-job`, sourceProvider }],
					nextCursor: `${sourceProvider}-cursor-3`
				}
			});
			expect(JSON.stringify(result)).not.toContain('jwt-secret-canary');
		}
	);

	it.each(INVALID_SOURCE_PROVIDERS)(
		'recentImports rejects invalid source_provider %s before invoking a migration client method',
		async (sourceProvider) => {
			const result = await actions.recentImports({
				request: actionRequest({
					source_provider: sourceProvider,
					cursor: 'cursor_2',
					limit: '10'
				}),
				locals: { user: { token: 'jwt-secret-canary' } }
			} as never);

			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: {
						error: 'source_provider_unsupported',
						code: 'source_provider_unsupported'
					}
				})
			);
			expect(listMigrationImportJobsMock).not.toHaveBeenCalled();
			expect(listAlgoliaImportJobsMock).not.toHaveBeenCalled();
		}
	);

	it('recentImports action maps 401/403 through the dashboard auth contract', async () => {
		listMigrationImportJobsMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await actions.recentImports({
			request: actionRequest({
				source_provider: 'algolia',
				cursor: 'cursor_2',
				limit: '10'
			}),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({ _authSessionExpired: true, error: 'Unauthorized' })
			})
		);
	});

	it('load maps session failures through the dashboard auth contract', async () => {
		getMigrationAvailabilityMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

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

	it('exports only the server-owned migration action bridge names', () => {
		expect(Object.keys(actions).sort()).toEqual([
			'availability',
			'checkDestinationEligibility',
			'createImportJob',
			'listSourceIndexes',
			'previewImport',
			'providerEligibility',
			'recentImports'
		]);
	});

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'providerEligibility forwards selected source_provider %s and mints the coarse create envelope without a destination name',
		async (sourceProvider) => {
			const result = await actions.providerEligibility({
				request: payloadRequest({ source_provider: sourceProvider, region: 'us-east-1' }),
				locals: { user: { token: 'jwt-secret-canary' } }
			} as never);

			expect(checkMigrationDestinationEligibilityMock).toHaveBeenCalledWith(sourceProvider, {
				phase: 'provider',
				mode: 'create',
				target: { region: 'us-east-1', name: '' }
			} satisfies AlgoliaDestinationEligibilityRequest);
			expect(checkAlgoliaDestinationEligibilityMock).not.toHaveBeenCalled();
			expect(JSON.stringify(result)).not.toContain('jwt-secret-canary');
			expect(JSON.stringify(result)).not.toContain('algolia_api_key_canary');
			expect(result).toEqual({
				providerEligibility: {
					phase: 'provider',
					mode: 'create',
					provider: 'aws',
					target: { kind: 'create', region: 'us-east-1' },
					eligibilityToken: 'provider-token',
					expiresAt: '2099-07-18T10:15:00Z'
				}
			});
		}
	);

	it('providerEligibility action rejects malformed JSON payloads with a 400 action failure', async () => {
		const result = await actions.providerEligibility({
			request: actionRequest({ payload: '{"region":' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: { error: 'Invalid payload' }
			})
		);
		expect(checkAlgoliaDestinationEligibilityMock).not.toHaveBeenCalled();
		expect(checkMigrationDestinationEligibilityMock).not.toHaveBeenCalled();
	});

	it.each(INVALID_SOURCE_PROVIDERS)(
		'providerEligibility rejects invalid source_provider %s before invoking a migration client method',
		async (sourceProvider) => {
			const result = await actions.providerEligibility({
				request: payloadRequest({ source_provider: sourceProvider, region: 'us-east-1' }),
				locals: { user: { token: 'jwt-secret-canary' } }
			} as never);

			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: {
						error: 'source_provider_unsupported',
						code: 'source_provider_unsupported'
					}
				})
			);
			expect(checkMigrationDestinationEligibilityMock).not.toHaveBeenCalled();
			expect(checkAlgoliaDestinationEligibilityMock).not.toHaveBeenCalled();
		}
	);
});
