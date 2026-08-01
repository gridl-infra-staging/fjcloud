import { beforeEach, describe, expect, it, vi } from 'vitest';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { stringify } from 'devalue';
import { ApiRequestError } from '$lib/api/client';
import type { CreateAlgoliaImportJobRequest, ListAlgoliaIndexesRequest } from '$lib/api/types';
vi.mock('$lib/server/api', async () => {
	const { createMigrationApiClientMock } = await import('./migrate_server_test_fixtures');
	return { createApiClient: vi.fn(createMigrationApiClientMock) };
});

import { actions, load } from './+page.server';
import {
	CLOSED_SOURCE_PROVIDERS,
	HOSTED_SOURCE_PROVIDERS,
	INVALID_SOURCE_PROVIDERS,
	actionRequest,
	checkAlgoliaDestinationEligibilityMock,
	checkMigrationDestinationEligibilityMock,
	createAlgoliaImportJobMock,
	createJobPayload,
	createMigrationImportJobMock,
	findDynamicRouteOwners,
	forwardedCreateBody,
	forwardedSourceCredentials,
	getMigrationAvailabilityMock,
	listAlgoliaImportJobsMock,
	listAlgoliaSourceIndexesMock,
	listMigrationImportJobsMock,
	listMigrationSourceIndexesMock,
	payloadRequest,
	resetMigrateServerMocks,
	sourceListPayload
} from './migrate_server_test_fixtures';

describe('Migrate page server actions and serialization', () => {
	beforeEach(resetMigrateServerMocks);

	it('listSourceIndexes and createImportJob forward credential-bearing payloads without echoing them', async () => {
		const listPayload = {
			appId: 'algolia_app_id_canary',
			apiKey: 'algolia_api_key_canary',
			cursor: 'cursor_1'
		} satisfies ListAlgoliaIndexesRequest;
		const createPayload = {
			mode: 'create',
			appId: 'algolia_app_id_canary',
			apiKey: 'algolia_api_key_canary',
			sourceName: 'source_products',
			target: { eligibilityToken: 'target-token-canary' }
		} satisfies CreateAlgoliaImportJobRequest;

		const listResult = await actions.listSourceIndexes({
			request: payloadRequest({ source_provider: 'algolia', ...listPayload }),
			locals: { user: { token: 'jwt-secret-canary' } }
		} as never);
		const createResult = await actions.createImportJob({
			request: payloadRequest(
				{ source_provider: 'algolia', ...createPayload },
				{ idempotencyKey: 'idem-key-canary' }
			),
			locals: { user: { token: 'jwt-secret-canary' } }
		} as never);

		expect(listMigrationSourceIndexesMock).toHaveBeenCalledWith('algolia', listPayload);
		expect(createMigrationImportJobMock).toHaveBeenCalledWith(
			'algolia',
			createPayload,
			'idem-key-canary'
		);
		for (const result of [listResult, createResult]) {
			const serialized = JSON.stringify(result);
			expect(serialized).not.toContain('jwt-secret-canary');
			expect(serialized).not.toContain('algolia_app_id_canary');
			expect(serialized).not.toContain('algolia_api_key_canary');
			expect(serialized).not.toContain('idem-key-canary');
		}
	});

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'keeps %s post-submit credentials out of __data.json-compatible route serialization',
		async (sourceProvider) => {
			const payload = createJobPayload(sourceProvider);
			const forwardedBody = forwardedCreateBody(payload);
			const idempotencyKey = `${sourceProvider}-idempotency-key-canary`;
			createMigrationImportJobMock.mockResolvedValue({
				id: `${sourceProvider}-job`,
				sourceProvider
			});

			const result = await actions.createImportJob({
				request: payloadRequest(payload, { idempotencyKey }),
				locals: { user: { token: 'jwt-secret-canary' } }
			} as never);
			const serializedRouteData = stringify(result);

			expect(result).toEqual({
				job: { id: `${sourceProvider}-job`, sourceProvider }
			});
			expect(serializedRouteData).toContain(`${sourceProvider}-job`);
			for (const forbidden of [
				'jwt-secret-canary',
				payload.apiKey,
				'appId' in payload ? payload.appId : payload.host,
				payload.target.eligibilityToken,
				idempotencyKey
			]) {
				expect(serializedRouteData).not.toContain(forbidden);
			}
			expect(createMigrationImportJobMock).toHaveBeenCalledWith(
				sourceProvider,
				forwardedBody,
				idempotencyKey
			);
		}
	);

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'listSourceIndexes forwards selected source_provider %s to the neutral API client method',
		async (sourceProvider) => {
			const payload = sourceListPayload(sourceProvider);

			const result = await actions.listSourceIndexes({
				request: payloadRequest(payload),
				locals: { user: { token: 'jwt-secret-canary' } }
			} as never);

			expect(listMigrationSourceIndexesMock).toHaveBeenCalledOnce();
			expect(listMigrationSourceIndexesMock).toHaveBeenCalledWith(
				sourceProvider,
				forwardedSourceCredentials(payload)
			);
			expect(listAlgoliaSourceIndexesMock).not.toHaveBeenCalled();
			expect(JSON.stringify(result)).not.toContain('jwt-secret-canary');
			expect(JSON.stringify(result)).not.toContain(payload.apiKey);
		}
	);

	it.each(INVALID_SOURCE_PROVIDERS)(
		'listSourceIndexes rejects invalid source_provider %s before invoking a migration client method',
		async (sourceProvider) => {
			const payload = {
				...sourceListPayload('algolia'),
				source_provider: sourceProvider
			};

			const result = await actions.listSourceIndexes({
				request: payloadRequest(payload),
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
			expect(listMigrationSourceIndexesMock).not.toHaveBeenCalled();
			expect(listAlgoliaSourceIndexesMock).not.toHaveBeenCalled();
		}
	);

	it.each([
		'http://typesense.example.test',
		'https://localhost',
		'https://127.0.0.1',
		'https://typesense.example.test:8443',
		'https://typesense.example.test/admin',
		'https://user:pass@typesense.example.test'
	])(
		'listSourceIndexes rejects unsafe hosted source host %s before invoking the client',
		async (host) => {
			const payload = {
				...sourceListPayload('typesense'),
				host
			};

			const result = await actions.listSourceIndexes({
				request: payloadRequest(payload),
				locals: { user: { token: 'jwt-secret-canary' } }
			} as never);

			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: { error: 'Host URL must be a public https origin' }
				})
			);
			expect(listMigrationSourceIndexesMock).not.toHaveBeenCalled();
			expect(listAlgoliaSourceIndexesMock).not.toHaveBeenCalled();
		}
	);

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'checkDestinationEligibility forwards selected source_provider %s to the neutral API client method',
		async (sourceProvider) => {
			const payload = {
				source_provider: sourceProvider,
				phase: 'target',
				mode: 'create',
				target: { region: 'us-east-1', name: `${sourceProvider}_products` },
				eligibilityToken: `${sourceProvider}-provider-token`
			};

			await actions.checkDestinationEligibility({
				request: payloadRequest(payload),
				locals: { user: { token: 'jwt-secret-canary' } }
			} as never);

			expect(checkMigrationDestinationEligibilityMock).toHaveBeenCalledOnce();
			expect(checkMigrationDestinationEligibilityMock).toHaveBeenCalledWith(sourceProvider, {
				phase: 'target',
				mode: 'create',
				target: { region: 'us-east-1', name: `${sourceProvider}_products` },
				eligibilityToken: `${sourceProvider}-provider-token`
			});
			expect(checkAlgoliaDestinationEligibilityMock).not.toHaveBeenCalled();
		}
	);

	it.each(INVALID_SOURCE_PROVIDERS)(
		'checkDestinationEligibility rejects invalid source_provider %s before invoking a migration client method',
		async (sourceProvider) => {
			const payload = {
				source_provider: sourceProvider,
				phase: 'target',
				mode: 'create',
				target: { region: 'us-east-1', name: 'invalid_provider_products' },
				eligibilityToken: 'invalid-provider-token'
			};

			const result = await actions.checkDestinationEligibility({
				request: payloadRequest(payload),
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

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'createImportJob forwards selected source_provider %s and exact body to the neutral API client method',
		async (sourceProvider) => {
			const payload = createJobPayload(sourceProvider);

			await actions.createImportJob({
				request: payloadRequest(payload, { idempotencyKey: `${sourceProvider}-idem-key` }),
				locals: { user: { token: 'jwt-secret-canary' } }
			} as never);

			expect(createMigrationImportJobMock).toHaveBeenCalledOnce();
			expect(createMigrationImportJobMock).toHaveBeenCalledWith(
				sourceProvider,
				forwardedCreateBody(payload),
				`${sourceProvider}-idem-key`
			);
			expect(createAlgoliaImportJobMock).not.toHaveBeenCalled();
		}
	);

	it.each([
		['createImportJob', actions.createImportJob],
		['recentImports', actions.recentImports]
	] as const)(
		'%s maps request form-data parsing failures to a 400 action failure',
		async (_actionName, action) => {
			const request = {
				formData: vi.fn().mockRejectedValue(new Error('malformed multipart body'))
			};

			const result = await action({
				request,
				locals: { user: { token: 'jwt-secret-canary' } }
			} as never);

			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: { error: 'Migration request failed' }
				})
			);
			expect(createMigrationImportJobMock).not.toHaveBeenCalled();
			expect(listMigrationImportJobsMock).not.toHaveBeenCalled();
		}
	);

	it.each(INVALID_SOURCE_PROVIDERS)(
		'createImportJob rejects invalid source_provider %s before invoking a migration client method',
		async (sourceProvider) => {
			const payload = {
				...createJobPayload('algolia'),
				source_provider: sourceProvider
			};

			const result = await actions.createImportJob({
				request: payloadRequest(payload, { idempotencyKey: 'invalid-provider-idem-key' }),
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
			expect(createMigrationImportJobMock).not.toHaveBeenCalled();
			expect(createAlgoliaImportJobMock).not.toHaveBeenCalled();
		}
	);

	it.each(HOSTED_SOURCE_PROVIDERS)(
		'createImportJob rejects localhost-style %s source hosts before invoking the client',
		async (sourceProvider) => {
			const payload = {
				...createJobPayload(sourceProvider),
				host: 'https://127.0.0.1'
			};

			const result = await actions.createImportJob({
				request: payloadRequest(payload, { idempotencyKey: `${sourceProvider}-idem-key` }),
				locals: { user: { token: 'jwt-secret-canary' } }
			} as never);

			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: { error: 'Host URL must be a public https origin' }
				})
			);
			expect(createMigrationImportJobMock).not.toHaveBeenCalled();
			expect(createAlgoliaImportJobMock).not.toHaveBeenCalled();
		}
	);

	it.each([
		{
			actionName: 'providerEligibility',
			invoke: () =>
				actions.providerEligibility({
					request: payloadRequest({ region: 'us-east-1' }),
					locals: { user: { token: 'jwt-secret-canary' } }
				} as never),
			clientMocks: [
				checkMigrationDestinationEligibilityMock,
				checkAlgoliaDestinationEligibilityMock
			]
		},
		{
			actionName: 'recentImports',
			invoke: () =>
				actions.recentImports({
					request: actionRequest({ cursor: 'cursor_2', limit: '10' }),
					locals: { user: { token: 'jwt-secret-canary' } }
				} as never),
			clientMocks: [listMigrationImportJobsMock, listAlgoliaImportJobsMock]
		},
		{
			actionName: 'listSourceIndexes',
			invoke: () =>
				actions.listSourceIndexes({
					request: payloadRequest({
						appId: 'algolia_app_id_canary',
						apiKey: 'algolia_api_key_canary',
						cursor: 'cursor_2'
					}),
					locals: { user: { token: 'jwt-secret-canary' } }
				} as never),
			clientMocks: [listMigrationSourceIndexesMock, listAlgoliaSourceIndexesMock]
		},
		{
			actionName: 'checkDestinationEligibility',
			invoke: () =>
				actions.checkDestinationEligibility({
					request: payloadRequest({
						phase: 'target',
						mode: 'create',
						target: { region: 'us-east-1', name: 'products' },
						eligibilityToken: 'provider-token'
					}),
					locals: { user: { token: 'jwt-secret-canary' } }
				} as never),
			clientMocks: [
				checkMigrationDestinationEligibilityMock,
				checkAlgoliaDestinationEligibilityMock
			]
		},
		{
			actionName: 'createImportJob',
			invoke: () =>
				actions.createImportJob({
					request: payloadRequest(
						{
							mode: 'create',
							appId: 'algolia_app_id_canary',
							apiKey: 'algolia_api_key_canary',
							sourceName: 'products',
							target: { eligibilityToken: 'target-token' }
						},
						{ idempotencyKey: 'missing-provider-idem-key' }
					),
					locals: { user: { token: 'jwt-secret-canary' } }
				} as never),
			clientMocks: [createMigrationImportJobMock, createAlgoliaImportJobMock]
		}
	])(
		'$actionName rejects a missing source_provider before invoking a migration client method',
		async ({ invoke, clientMocks }) => {
			const result = await invoke();

			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: {
						error: 'source_provider_unsupported',
						code: 'source_provider_unsupported'
					}
				})
			);
			for (const clientMock of clientMocks) {
				expect(clientMock).not.toHaveBeenCalled();
			}
		}
	);

	it('returns the neutral failure shape for source_provider_unsupported without rewriting it as a destination failure', async () => {
		listMigrationSourceIndexesMock.mockRejectedValue(
			new ApiRequestError(400, 'source_provider_unsupported', {
				body: {
					code: 'source_provider_unsupported',
					error: 'source_provider_unsupported'
				}
			})
		);

		const result = await actions.listSourceIndexes({
			request: payloadRequest({
				source_provider: 'typesense',
				host: 'https://typesense.example.test',
				apiKey: 'typesense_api_key_canary'
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
		expect(JSON.stringify(result)).not.toContain('migration_provider_unsupported');
	});

	it('createImportJob action rejects malformed JSON payloads before calling the API client', async () => {
		const result = await actions.createImportJob({
			request: actionRequest({
				payload: '{"mode":"create"',
				idempotencyKey: 'idem-key-canary'
			}),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: { error: 'Invalid payload' }
			})
		);
		expect(createAlgoliaImportJobMock).not.toHaveBeenCalled();
	});

	it.each(['', ' idem-key', 'idem key', 'idem\r\nx-test: injected', 'a'.repeat(129)])(
		'createImportJob rejects malformed idempotency key %j before calling the API client',
		async (idempotencyKey) => {
			const result = await actions.createImportJob({
				request: payloadRequest(
					{
						source_provider: 'algolia',
						mode: 'create',
						appId: 'algolia_app_id_canary',
						apiKey: 'algolia_api_key_canary',
						sourceName: 'products',
						target: { eligibilityToken: 'target-token' }
					},
					{ idempotencyKey }
				),
				locals: { user: { token: 'jwt' } }
			} as never);

			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: {
						error: idempotencyKey === '' ? 'Missing idempotency key' : 'Invalid idempotency key'
					}
				})
			);
			expect(createMigrationImportJobMock).not.toHaveBeenCalled();
			expect(createAlgoliaImportJobMock).not.toHaveBeenCalled();
		}
	);

	it('does not lift Algolia credentials or a source catalog into SSR load data', async () => {
		const result = (await load({
			locals: { user: { token: 'jwt' } }
		} as never)) as Record<string, unknown>;

		// Algolia credentials are contractually volatile client-side state. Any
		// appearance in load data would serialize them into the SSR payload.
		for (const forbiddenKey of ['appId', 'apiKey', 'sources', 'sourceIndexes', 'eligibility']) {
			expect(result).not.toHaveProperty(forbiddenKey);
		}
		// The load key set intentionally expands to carry the SSR recent-import
		// page alongside availability, but nothing else may leak into SSR data.
		expect(Object.keys(result).sort()).toEqual(['availability', 'recentImports']);
	});

	it('serializes only availability data and never the customer token or dormant import state', async () => {
		getMigrationAvailabilityMock.mockResolvedValue({
			available: false,
			reason: 'temporarily_unavailable',
			message: 'Algolia migration is temporarily unavailable while we replace the importer.',
			capabilities: { cancel: false, resume: false, replace: false }
		});

		const result = (await load({
			locals: { user: { token: 'jwt-secret-canary' } }
		} as never)) as Record<string, unknown>;
		const serialized = JSON.stringify(result);

		expect(result).toEqual({
			availability: {
				available: false,
				reason: 'temporarily_unavailable',
				message: 'Algolia migration is temporarily unavailable while we replace the importer.',
				capabilities: { cancel: false, resume: false, replace: false }
			},
			recentImports: { page: null, error: null }
		});
		for (const forbidden of [
			'jwt-secret-canary',
			'algolia_app_id_canary',
			'algolia_api_key_canary',
			'sourceIndexes',
			'sourceCatalog',
			'eligibilityToken',
			'previewUrl',
			'resumeCheckpoint'
		]) {
			expect(serialized).not.toContain(forbidden);
		}
	});

	it('detects route owners anywhere below a dynamic migration segment', () => {
		const routeDir = mkdtempSync(join(tmpdir(), 'migration-route-guard-'));

		try {
			for (const relativeDir of ['[jobId]', '[jobId]/details', '[jobId]/details/api', 'help']) {
				mkdirSync(join(routeDir, relativeDir), { recursive: true });
			}
			writeFileSync(join(routeDir, '[jobId]/+page.server.ts'), '');
			writeFileSync(join(routeDir, '[jobId]/details/+page.svelte'), '');
			writeFileSync(join(routeDir, '[jobId]/details/api/+server.ts'), '');
			writeFileSync(join(routeDir, 'help/+page.svelte'), '');

			expect(findDynamicRouteOwners(routeDir, '').sort()).toEqual([
				'[jobId]/+page.server.ts',
				'[jobId]/details/+page.svelte',
				'[jobId]/details/api/+server.ts'
			]);
		} finally {
			rmSync(routeDir, { recursive: true, force: true });
		}
	});

	it('fails loudly when the root migrate route directory cannot be read', () => {
		// The guard's whole purpose is to prove no dynamic route owner is served
		// under src/routes/console/migrate. If the root path is misresolved (wrong
		// cwd) or otherwise unreadable, swallowing the readdirSync error and
		// returning [] would let the guard pass vacuously. A missing root must
		// throw so the guard cannot be silently defeated.
		const missingRoot = join(tmpdir(), 'migration-route-guard-missing-root-does-not-exist');
		expect(existsSync(missingRoot)).toBe(false);
		expect(() => findDynamicRouteOwners(missingRoot, '')).toThrow();
	});

	it('serves only the intended [jobId] job-detail dynamic route owners', () => {
		const migrateRouteDir = join(process.cwd(), 'src/routes/console/migrate');

		// Prove the guard is pointed at a real, readable directory so the result
		// cannot come from a misresolved or unreadable root path.
		expect(existsSync(migrateRouteDir)).toBe(true);

		// Stage 3 serves exactly the [jobId] detail route: its server contract and
		// its page. Any other dynamic owner (a nested proxy, a token endpoint, a
		// second job-detail route) must make this fail.
		const dynamicRouteOwners = findDynamicRouteOwners(migrateRouteDir, '').sort();
		expect(dynamicRouteOwners).toEqual(['[jobId]/+page.server.ts', '[jobId]/+page.svelte']);
	});
});
