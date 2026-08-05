import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
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

// Lazy Proxy, not a snapshot object literal: a literal is evaluated once at
// module load, so per-test `process.env` mutation would never be observed and a
// flag-gated test would pass without the flag ever reaching the server module.
vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

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
	previewMigrationImportMock,
	previewPayload,
	resetMigrateServerMocks,
	sourceListPayload
} from './migrate_server_test_fixtures';

const ALLOW_LOOPBACK_SOURCE_ORIGINS_FLAG = 'FJCLOUD_ALLOW_LOOPBACK_SOURCE_ORIGINS';

// The payload fixtures return a union across every closed provider, and a bare
// `{ ...fixture, host }` spread widens `source_provider` back to `string` while
// keeping the Algolia arm's `appId`, so the result matches neither union arm and
// can no longer be handed to forwardedSourceCredentials/forwardedCreateBody.
// Overriding `host` never changes which arm the value really is, so restoring
// the fixture's own return type here is sound — and keeps the fixtures the
// single owner of the default payload shape.
function withSourceHost<T extends object>(payload: T, host: string): T {
	return { ...payload, host } as T;
}

function invokeAction<T>(
	action: (event: never) => T,
	request: unknown,
	token = 'jwt-secret-canary'
): T {
	return action({ request, locals: { user: { token } } } as never);
}

async function expectSourceHostRejected(host: string) {
	const payload = withSourceHost(sourceListPayload('typesense'), host);

	const result = await invokeAction(actions.listSourceIndexes, payloadRequest(payload));

	expect(result).toEqual(
		expect.objectContaining({
			status: 400,
			data: { error: 'Host URL must be a public https origin' }
		})
	);
	expect(listMigrationSourceIndexesMock).not.toHaveBeenCalled();
	expect(listAlgoliaSourceIndexesMock).not.toHaveBeenCalled();
}

// File-scoped on purpose. The pre-existing unsafe-host rejection tables assert
// that loopback hosts are refused, which only holds while the opt-in flag is
// absent, so leaking it out of a loopback case would silently break tests this
// lane does not own.
afterEach(() => {
	delete process.env[ALLOW_LOOPBACK_SOURCE_ORIGINS_FLAG];
});

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

		const listResult = await invokeAction(
			actions.listSourceIndexes,
			payloadRequest({ source_provider: 'algolia', ...listPayload })
		);
		const createResult = await invokeAction(
			actions.createImportJob,
			payloadRequest(
				{ source_provider: 'algolia', ...createPayload },
				{ idempotencyKey: 'idem-key-canary' }
			)
		);

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

			const result = await invokeAction(
				actions.createImportJob,
				payloadRequest(payload, { idempotencyKey })
			);
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

			const result = await invokeAction(actions.listSourceIndexes, payloadRequest(payload));

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

			const result = await invokeAction(actions.listSourceIndexes, payloadRequest(payload));

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
		'https://user:pass@typesense.example.test',
		'http://127.0.0.1:8108',
		'http://localhost:8108',
		'http://[::1]:8108'
	])(
		'listSourceIndexes rejects unsafe hosted source host %s before invoking the client',
		async (host) => {
			await expectSourceHostRejected(host);
		}
	);

	it.each([
		'http://10.0.0.5:8108',
		'http://192.168.1.10:8108',
		'http://169.254.169.254/',
		'http://meili.example.test:8108',
		'https://user:pass@127.0.0.1:8108',
		'http://127.0.0.1:8108/admin',
		'http://127.0.0.1:8108/?x=1',
		'http://127.0.0.1:8108/#f',
		'http://127.0.0.1.evil.test:8108',
		'http://localhost.evil.test:8108'
	])(
		'listSourceIndexes still rejects unsafe hosted source host %s when loopback opt-in is set',
		async (host) => {
			process.env[ALLOW_LOOPBACK_SOURCE_ORIGINS_FLAG] = '1';
			await expectSourceHostRejected(host);
		}
	);

	it.each(['', '0', 'false', 'true', 'yes'])(
		'listSourceIndexes rejects loopback source hosts when opt-in flag value is %s',
		async (flagValue) => {
			process.env[ALLOW_LOOPBACK_SOURCE_ORIGINS_FLAG] = flagValue;
			await expectSourceHostRejected('http://127.0.0.1:8108');
		}
	);

	// All three loopback literals, not just 127.0.0.1: each one takes a different
	// branch of the rejection condition (IP-literal regex, the `localhost` name
	// check, and IPv6 — whose `URL.hostname` is the bracketed `[::1]`), so a
	// single-host case would let two of the three stay silently refused.
	it.each(['http://127.0.0.1:8108', 'http://localhost:8108', 'http://[::1]:8108'])(
		'listSourceIndexes forwards loopback source host %s unchanged when the loopback opt-in is set',
		async (host) => {
			process.env[ALLOW_LOOPBACK_SOURCE_ORIGINS_FLAG] = '1';
			const payload = withSourceHost(sourceListPayload('typesense'), host);

			const result = await invokeAction(actions.listSourceIndexes, payloadRequest(payload));

			// Asserted first so a still-rejecting server prints the customer-visible
			// 400 / 'Host URL must be a public https origin' payload as the failure,
			// rather than a bare never-called-spy message that hides the real cause.
			expect(result).toEqual({ sourceIndexes: { items: [], nextCursor: null } });
			// Each loopback input is already exactly its own URL origin, so the
			// forwarded host must come back byte-identical with port 8108 intact.
			expect(listMigrationSourceIndexesMock).toHaveBeenCalledWith(
				'typesense',
				forwardedSourceCredentials(payload)
			);
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

			await invokeAction(actions.checkDestinationEligibility, payloadRequest(payload));

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

			const result = await invokeAction(
				actions.checkDestinationEligibility,
				payloadRequest(payload)
			);

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

			await invokeAction(
				actions.createImportJob,
				payloadRequest(payload, { idempotencyKey: `${sourceProvider}-idem-key` })
			);

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

			const result = await invokeAction(
				actions.createImportJob,
				payloadRequest(payload, { idempotencyKey: 'invalid-provider-idem-key' })
			);

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

			const result = await invokeAction(
				actions.createImportJob,
				payloadRequest(payload, { idempotencyKey: `${sourceProvider}-idem-key` })
			);

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

	it('createImportJob forwards a loopback source host unchanged when the loopback opt-in is set', async () => {
		process.env[ALLOW_LOOPBACK_SOURCE_ORIGINS_FLAG] = '1';
		const payload = withSourceHost(createJobPayload('typesense'), 'http://127.0.0.1:8108');

		const result = await invokeAction(
			actions.createImportJob,
			payloadRequest(payload, { idempotencyKey: 'typesense-idem-key' })
		);

		// Result first, for the same red-evidence reason as the listSourceIndexes case.
		expect(result).toEqual({ job: { id: 'job_123' } });
		expect(createMigrationImportJobMock).toHaveBeenCalledWith(
			'typesense',
			forwardedCreateBody(payload),
			'typesense-idem-key'
		);
		expect(createAlgoliaImportJobMock).not.toHaveBeenCalled();
	});

	it.each([
		{
			sourceProvider: 'meilisearch' as const,
			expectedBody: {
				endpoint: 'https://meilisearch.example.test',
				apiKey: 'meilisearch_api_key_canary',
				sourceIndex: 'configured_pk',
				targetIndex: 'configured_pk',
				overwrite: false
			}
		},
		{
			sourceProvider: 'algolia' as const,
			expectedBody: {
				appId: 'algolia_app_id_canary',
				apiKey: 'algolia_api_key_canary',
				sourceIndex: 'algolia_products',
				targetIndex: 'algolia_target',
				overwrite: false
			}
		}
	])(
		'previewImport forwards the exact published $sourceProvider preview body without allocating a job',
		async ({ sourceProvider, expectedBody }) => {
			const result = await invokeAction(
				actions.previewImport,
				payloadRequest(previewPayload(sourceProvider))
			);

			expect(result).toEqual({
				preview: {
					sourceCounts: { indexes: 1, records: 4 },
					report: {
						summary: { totalEntries: 0, hardRejections: 0, warnings: 0, scopeGaps: 0 },
						entries: [],
						reportDigest: 'sha256:test-preview'
					}
				}
			});
			expect(previewMigrationImportMock).toHaveBeenCalledWith(sourceProvider, expectedBody);
			expect(createMigrationImportJobMock).not.toHaveBeenCalled();
		}
	);

	it('previewImport rejects Typesense because it is not a supported preview provider', async () => {
		const result = await invokeAction(
			actions.previewImport,
			payloadRequest({
				source_provider: 'typesense',
				endpoint: 'https://typesense.example.test',
				apiKey: 'typesense_api_key_canary',
				sourceIndex: 'products',
				targetIndex: 'products',
				overwrite: false
			})
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: {
					error: 'source_provider_unsupported',
					code: 'source_provider_unsupported'
				}
			})
		);
		expect(previewMigrationImportMock).not.toHaveBeenCalled();
		expect(createMigrationImportJobMock).not.toHaveBeenCalled();
	});

	it('previewImport rejects loopback Meilisearch endpoints when the loopback opt-in is unset', async () => {
		const result = await invokeAction(
			actions.previewImport,
			payloadRequest({
				...previewPayload('meilisearch'),
				endpoint: 'http://127.0.0.1:17700'
			})
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: { error: 'Host URL must be a public https origin' }
			})
		);
		expect(previewMigrationImportMock).not.toHaveBeenCalled();
	});

	it('previewImport allows loopback Meilisearch endpoints when the loopback opt-in is set', async () => {
		process.env[ALLOW_LOOPBACK_SOURCE_ORIGINS_FLAG] = '1';

		await invokeAction(
			actions.previewImport,
			payloadRequest({
				...previewPayload('meilisearch'),
				endpoint: 'http://127.0.0.1:17700'
			})
		);

		expect(previewMigrationImportMock).toHaveBeenCalledWith('meilisearch', {
			endpoint: 'http://127.0.0.1:17700',
			apiKey: 'meilisearch_api_key_canary',
			sourceIndex: 'configured_pk',
			targetIndex: 'configured_pk',
			overwrite: false
		});
		expect(createMigrationImportJobMock).not.toHaveBeenCalled();
	});

	it.each([
		{
			actionName: 'providerEligibility',
			invoke: () =>
				invokeAction(actions.providerEligibility, payloadRequest({ region: 'us-east-1' })),
			clientMocks: [
				checkMigrationDestinationEligibilityMock,
				checkAlgoliaDestinationEligibilityMock
			]
		},
		{
			actionName: 'recentImports',
			invoke: () =>
				invokeAction(actions.recentImports, actionRequest({ cursor: 'cursor_2', limit: '10' })),
			clientMocks: [listMigrationImportJobsMock, listAlgoliaImportJobsMock]
		},
		{
			actionName: 'listSourceIndexes',
			invoke: () =>
				invokeAction(
					actions.listSourceIndexes,
					payloadRequest({
						appId: 'algolia_app_id_canary',
						apiKey: 'algolia_api_key_canary',
						cursor: 'cursor_2'
					})
				),
			clientMocks: [listMigrationSourceIndexesMock, listAlgoliaSourceIndexesMock]
		},
		{
			actionName: 'checkDestinationEligibility',
			invoke: () =>
				invokeAction(
					actions.checkDestinationEligibility,
					payloadRequest({
						phase: 'target',
						mode: 'create',
						target: { region: 'us-east-1', name: 'products' },
						eligibilityToken: 'provider-token'
					})
				),
			clientMocks: [
				checkMigrationDestinationEligibilityMock,
				checkAlgoliaDestinationEligibilityMock
			]
		},
		{
			actionName: 'createImportJob',
			invoke: () =>
				invokeAction(
					actions.createImportJob,
					payloadRequest(
						{
							mode: 'create',
							appId: 'algolia_app_id_canary',
							apiKey: 'algolia_api_key_canary',
							sourceName: 'products',
							target: { eligibilityToken: 'target-token' }
						},
						{ idempotencyKey: 'missing-provider-idem-key' }
					)
				),
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

		const result = await invokeAction(
			actions.listSourceIndexes,
			payloadRequest({
				source_provider: 'typesense',
				host: 'https://typesense.example.test',
				apiKey: 'typesense_api_key_canary'
			})
		);

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
		const result = await invokeAction(
			actions.createImportJob,
			actionRequest({
				payload: '{"mode":"create"',
				idempotencyKey: 'idem-key-canary'
			}),
			'jwt'
		);

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
			const result = await invokeAction(
				actions.createImportJob,
				payloadRequest(
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
				'jwt'
			);

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
			capabilities: { cancel: false, resume: false, replace: false, preview: false }
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
				capabilities: { cancel: false, resume: false, replace: false, preview: false }
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
