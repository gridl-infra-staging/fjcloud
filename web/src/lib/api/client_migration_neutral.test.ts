import { beforeEach, describe, expect, expectTypeOf, it } from 'vitest';
import type {
	AlgoliaDestinationEligibilityRequest,
	AlgoliaDestinationEligibilityResponse,
	AlgoliaMigrationAvailabilityResponse,
	AlgoliaMigrationPreviewRequest,
	AlgoliaSourceListResponse,
	CancelAlgoliaImportJobRequest,
	MeilisearchMigrationPreviewRequest,
	VerifySourceMigrationHitComparison,
	VerifySourceMigrationQueryReport,
	VerifySourceMigrationRequest,
	VerifySourceMigrationResponse,
	PublicAlgoliaImportJobPage,
	MigrationPreviewArguments
} from './types';
import { MIGRATION_PREVIEW_SOURCE_PROVIDERS } from './types';
import { BASE_URL, createAuthenticatedClient, mockFetch } from './client.test.shared';
import {
	AUTH_HEADERS,
	expectApiRequestError,
	CLOSED_SOURCE_PROVIDERS,
	HOSTED_SOURCE_INDEXES_WIRE_RESPONSE,
	HOSTED_SOURCE_INDEXES_NORMALIZED_RESPONSE,
	HOSTED_SOURCE_INDEX_EXPECTED_PAIRS,
	VOLATILE_SOURCE_CREDENTIALS,
	fullSourceMetadata,
	mockFetchWithHeaders,
	neutralCreateRequest,
	neutralPreviewArguments,
	neutralSourceListRequest,
	previewResponse,
	publicJob,
	requestJsonBody,
	requestInit,
	requestUrl,
	serializedRequest,
	verifySourceMigrationRequest,
	verifySourceMigrationResponse,
	type NeutralMigrationClient,
	type NeutralResumeRequest,
	type PublicJobWithSourceProvider
} from './client_migration_test_fixtures';

type ExpectedMigrationPreviewArguments =
	| [sourceProvider: 'algolia', request: AlgoliaMigrationPreviewRequest]
	| [sourceProvider: 'meilisearch', request: MeilisearchMigrationPreviewRequest];

function sourceIndexPairs(response: AlgoliaSourceListResponse) {
	return response.items?.map(({ name, entries }) => ({ name, entries }));
}

describe('ApiClient - neutral migration source provider contract', () => {
	let client: NeutralMigrationClient;

	beforeEach(() => {
		client = createAuthenticatedClient() as NeutralMigrationClient;
	});

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'GET /migration/%s/availability returns the selected neutral availability response',
		async (sourceProvider) => {
			const expected: AlgoliaMigrationAvailabilityResponse = {
				available: true,
				message: `${sourceProvider} migration is available.`,
				capabilities: {
					cancel: true,
					resume: true,
					replace: sourceProvider === 'algolia',
					preview: true,
					verify: false
				}
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getMigrationAvailability(sourceProvider);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/migration/${sourceProvider}/availability`, {
				method: 'GET',
				headers: AUTH_HEADERS
			});
			expect(result).toEqual(expected);
		}
	);

	it('preserves the complete Algolia page and cursor at the migration client boundary', async () => {
		const expected: AlgoliaSourceListResponse = {
			items: [fullSourceMetadata({ name: 'algolia_products' })],
			nextCursor: 'algolia/next-cursor'
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);
		const request = neutralSourceListRequest('algolia');

		const result = await client.listMigrationSourceIndexes('algolia', request);

		expect(requestUrl(fetch)).toBe(`${BASE_URL}/migration/algolia/list-indexes`);
		expect(requestJsonBody(fetch)).toEqual(request);
		expect(result).toEqual(expected);
	});

	it('normalizes a Meilisearch source-index page at the migration client boundary', async () => {
		const fetch = mockFetch(200, HOSTED_SOURCE_INDEXES_WIRE_RESPONSE);
		client.setFetch(fetch);
		const request = neutralSourceListRequest('meilisearch');

		const result = await client.listMigrationSourceIndexes('meilisearch', request);

		expect(requestUrl(fetch)).toBe(
			`${BASE_URL}/migration/meilisearch/list-indexes?offset=20&limit=25`
		);
		expect(requestJsonBody(fetch)).toEqual({
			endpoint: 'https://meilisearch.example.test',
			apiKey: 'meilisearch-neutral-source-key'
		});
		expect(result).toEqual(HOSTED_SOURCE_INDEXES_NORMALIZED_RESPONSE);
		expect(sourceIndexPairs(result)).toEqual(HOSTED_SOURCE_INDEX_EXPECTED_PAIRS);
	});

	it('moves Typesense offset pagination to the query and leaves only native credentials in the body', async () => {
		const fetch = mockFetch(200, { indexes: [], offset: 20, limit: 25, total: 0 });
		client.setFetch(fetch);
		const request = neutralSourceListRequest('typesense');

		const result = await client.listMigrationSourceIndexes('typesense', request);

		expect(requestUrl(fetch)).toBe(
			`${BASE_URL}/migration/typesense/list-indexes?offset=20&limit=25`
		);
		expect(requestJsonBody(fetch)).toEqual({
			node: 'https://typesense.example.test',
			apiKey: 'typesense-neutral-source-key'
		});
		expect(requestJsonBody(fetch)).not.toHaveProperty('host');
		expect(requestJsonBody(fetch)).not.toHaveProperty('cursor');
		expect(requestJsonBody(fetch)).not.toHaveProperty('hitsPerPage');
		expect(result).toEqual({ items: [], nextCursor: null });
	});

	it.each([
		{
			label: 'absent counts',
			index: { name: 'missing_counts' },
			expectedEntries: 0
		},
		{
			label: 'null counts',
			index: { name: 'null_counts', documentCount: null, entries: null },
			expectedEntries: 0
		}
	])('normalizes $label to zero records', async ({ index, expectedEntries }) => {
		const fetch = mockFetch(200, { indexes: [index], offset: 0, limit: 1, total: 1 });
		client.setFetch(fetch);

		const result = await client.listMigrationSourceIndexes('meilisearch', {
			endpoint: 'https://meilisearch.example.test',
			apiKey: 'meilisearch-neutral-source-key'
		});

		expect(result).toEqual({
			items: [
				{
					name: index.name,
					entries: expectedEntries,
					dataSize: 0,
					fileSize: 0,
					updatedAt: '',
					lastBuildTimeS: 0,
					pendingTask: false,
					primary: null,
					replicas: []
				}
			],
			nextCursor: null
		});
	});

	it.each([
		{ offset: 0, limit: 2, total: 3, expectedNextCursor: '2' },
		{ offset: 0, limit: 0, total: 3, expectedNextCursor: null },
		{ offset: 2, limit: 2, total: 3, expectedNextCursor: null }
	])(
		'exposes hosted offset $offset/$limit/$total as canonical cursor $expectedNextCursor',
		async ({ offset, limit, total, expectedNextCursor }) => {
			const fetch = mockFetch(200, { indexes: [], offset, limit, total });
			client.setFetch(fetch);

			const result = await client.listMigrationSourceIndexes('meilisearch', {
				endpoint: 'https://meilisearch.example.test',
				apiKey: 'meilisearch-neutral-source-key'
			});

			expect(result).toEqual({ items: [], nextCursor: expectedNextCursor });
		}
	);

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'POST /migration/%s/destination-eligibility forwards the neutral source provider path',
		async (sourceProvider) => {
			const expected: AlgoliaDestinationEligibilityResponse = {
				phase: 'target',
				mode: 'create',
				provider: 'aws',
				target: { kind: 'create', region: 'us-east-1', name: `${sourceProvider}_target` },
				eligibilityToken: `${sourceProvider}-target-token`,
				expiresAt: '2026-07-18T10:06:00Z'
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);
			const request: AlgoliaDestinationEligibilityRequest = {
				phase: 'target',
				mode: 'create',
				target: { region: 'us-east-1', name: `${sourceProvider}_target` },
				eligibilityToken: `${sourceProvider}-provider-token`
			};

			const result = await client.checkMigrationDestinationEligibility(sourceProvider, request);

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/migration/${sourceProvider}/destination-eligibility`,
				{
					method: 'POST',
					headers: AUTH_HEADERS,
					body: JSON.stringify(request)
				}
			);
			expect(result).toEqual(expected);
		}
	);

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'POST /migration/%s/jobs forwards the exact neutral create body and idempotency header',
		async (sourceProvider) => {
			const expected = publicJob({
				id: `${sourceProvider}-job`,
				sourceProvider,
				source: { name: `${sourceProvider}_products` }
			});
			const fetch = mockFetch(202, expected);
			client.setFetch(fetch);
			const request = neutralCreateRequest(sourceProvider);

			const result = await client.createMigrationImportJob(
				sourceProvider,
				request,
				`${sourceProvider}-idempotency-key`
			);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/migration/${sourceProvider}/jobs`, {
				method: 'POST',
				headers: { ...AUTH_HEADERS, 'idempotency-key': `${sourceProvider}-idempotency-key` },
				body: JSON.stringify(request)
			});
			expect(result).toEqual(expected);
			expect((result as PublicJobWithSourceProvider).sourceProvider).toBe(sourceProvider);
		}
	);

	it.each(MIGRATION_PREVIEW_SOURCE_PROVIDERS)(
		'POST /migration/%s/preview forwards the published provider-specific preview body',
		async (sourceProvider) => {
			const expected = previewResponse(sourceProvider);
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);
			const previewArguments = neutralPreviewArguments(sourceProvider);
			const request = previewArguments[1];

			const result = await client.previewMigrationImport(...previewArguments);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/migration/${sourceProvider}/preview`, {
				method: 'POST',
				headers: AUTH_HEADERS,
				body: JSON.stringify(request)
			});
			expect(result).toEqual(expected);
			expect(result.sourceCounts).toEqual({ indexes: 3, records: 42 });
			expect(result.report.summary).toEqual({
				totalEntries: 2,
				hardRejections: 1,
				warnings: 1,
				scopeGaps: 0
			});
			expect(result.report.entries[1]).toEqual({
				severity: 'HardRejection',
				code: 'MalformedDocumentPayload',
				resource: 'Document',
				pageIndex: 1,
				itemIndex: 7,
				jsonPath: '$.hits[7]'
			});
		}
	);

	it('previews without allocating a create idempotency key', async () => {
		const fetch = mockFetch(200, previewResponse('algolia'));
		client.setFetch(fetch);

		await client.previewMigrationImport(...neutralPreviewArguments('algolia'));

		const headers = requestInit(fetch).headers as Record<string, string>;
		expect(Object.keys(headers)).toEqual(['Content-Type', 'Authorization']);
		expect(headers['idempotency-key']).toBeUndefined();
	});

	it('POST /migration/algolia/verify forwards the exact verification body without a create idempotency key', async () => {
		const expected = verifySourceMigrationResponse();
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);
		const request = verifySourceMigrationRequest();

		const result = await client.verifySourceMigration('algolia', request);

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/migration/algolia/verify`, {
			method: 'POST',
			headers: AUTH_HEADERS,
			body: JSON.stringify(request)
		});
		expect(result).toEqual(expected);
		expect(result.queries[0]).toEqual({
			query: 'running shoes',
			overlapCount: 3,
			sourceOnly: ['p2'],
			destinationOnly: ['p5'],
			hits: [
				{ objectID: 'p1', sourceRank: 1, destinationRank: 3, rankDelta: 2 },
				{ objectID: 'p3', sourceRank: 3, destinationRank: 1, rankDelta: -2 },
				{ objectID: 'p4', sourceRank: 4, destinationRank: 4, rankDelta: 0 }
			]
		});
		const headers = requestInit(fetch).headers as Record<string, string>;
		expect(headers).toEqual(AUTH_HEADERS);
		expect(headers['idempotency-key']).toBeUndefined();
	});

	it('redacts structured verification error bodies while preserving public code and message fields', async () => {
		const request = verifySourceMigrationRequest();
		const fetch = mockFetchWithHeaders(
			403,
			{
				error: 'missing_source_permission',
				message: 'The source key cannot search source_products',
				code: 'missing_source_permission',
				appId: request.appId,
				apiKey: request.apiKey,
				nested: { authorization: `Bearer ${request.apiKey}`, message: 'public detail' }
			},
			{ 'x-request-id': 'verify-redaction-request' }
		);
		client.setFetch(fetch);

		await expectApiRequestError(() => client.verifySourceMigration('algolia', request), {
			status: 403,
			body: {
				error: 'missing_source_permission',
				message: 'The source key cannot search source_products',
				code: 'missing_source_permission',
				appId: '[REDACTED]',
				apiKey: '[REDACTED]',
				nested: { authorization: '[REDACTED]', message: 'public detail' }
			},
			requestId: 'verify-redaction-request'
		});
		expect(serializedRequest(fetch)).toContain(request.apiKey);
	});

	it('barrel-exports the exact source verification request and response shapes', () => {
		const request: VerifySourceMigrationRequest = verifySourceMigrationRequest();
		const hit: VerifySourceMigrationHitComparison = {
			objectID: 'p3',
			sourceRank: 3,
			destinationRank: 1,
			rankDelta: -2
		};
		const query: VerifySourceMigrationQueryReport = {
			query: 'running shoes',
			overlapCount: 3,
			sourceOnly: ['p2'],
			destinationOnly: ['p5'],
			hits: [hit]
		};
		const response: VerifySourceMigrationResponse = {
			sourceIndex: request.sourceIndex,
			destinationIndex: request.destinationIndex,
			resultLimit: request.resultLimit,
			queries: [query]
		};

		expect(request).toEqual({
			appId: 'ALGOLIA_VERIFY_APP_CANARY',
			apiKey: 'algolia-verify-key-canary',
			sourceIndex: 'source_products',
			destinationIndex: 'fj_products',
			queries: ['running shoes'],
			resultLimit: 4
		});
		expect(response.queries[0].hits[0]).toEqual({
			objectID: 'p3',
			sourceRank: 3,
			destinationRank: 1,
			rankDelta: -2
		});
	});

	it('redacts reflected source credentials from preview error bodies', async () => {
		const previewArguments = neutralPreviewArguments('meilisearch');
		const reflectedApiKey = previewArguments[1].apiKey;
		const fetch = mockFetchWithHeaders(
			400,
			{
				error: 'Preview rejected',
				apiKey: reflectedApiKey,
				nested: {
					token: 'server-generated-retry-token',
					context: 'keep this field'
				},
				events: [{ authorization: 'Bearer server-generated-access-token' }]
			},
			{ 'x-request-id': 'preview-redaction-request' }
		);
		client.setFetch(fetch);

		await expectApiRequestError(() => client.previewMigrationImport(...previewArguments), {
			status: 400,
			body: {
				error: 'Preview rejected',
				apiKey: '[REDACTED]',
				nested: {
					token: '[REDACTED]',
					context: 'keep this field'
				},
				events: [{ authorization: '[REDACTED]' }]
			},
			requestId: 'preview-redaction-request'
		});
	});

	it('exposes exactly one migration preview method and no per-provider preview aliases', () => {
		expectTypeOf<
			Parameters<typeof client.previewMigrationImport>
		>().toEqualTypeOf<ExpectedMigrationPreviewArguments>();
		expectTypeOf<MigrationPreviewArguments>().toEqualTypeOf<ExpectedMigrationPreviewArguments>();
		const methodNames: string[] = [];
		for (
			let prototype = Object.getPrototypeOf(client) as object | null;
			prototype !== null && prototype !== Object.prototype;
			prototype = Object.getPrototypeOf(prototype) as object | null
		) {
			methodNames.push(...Object.getOwnPropertyNames(prototype));
		}
		// `postPreviewEvent` belongs to search analytics, not migration, so match on
		// the migration/provider vocabulary rather than the bare word "preview".
		const migrationPreviewMethods = methodNames.filter((name) => {
			const lowercased = name.toLowerCase();
			return (
				lowercased.includes('preview') &&
				(lowercased.includes('migration') ||
					CLOSED_SOURCE_PROVIDERS.some((provider) => lowercased.includes(provider)))
			);
		});

		expect(migrationPreviewMethods).toEqual(['previewMigrationImport']);
	});

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'GET /migration/%s/jobs keeps retained import history provider-scoped',
		async (sourceProvider) => {
			const expected: PublicAlgoliaImportJobPage = {
				jobs: [
					publicJob({
						id: `${sourceProvider}-job`,
						sourceProvider,
						source: { name: `${sourceProvider}_products` }
					})
				],
				nextCursor: `${sourceProvider}-next`
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.listMigrationImportJobs(sourceProvider, {
				limit: 10,
				cursor: `${sourceProvider}-cursor`
			});

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/migration/${sourceProvider}/jobs?limit=10&cursor=${sourceProvider}-cursor`,
				{
					method: 'GET',
					headers: AUTH_HEADERS
				}
			);
			expect(result).toEqual(expected);
			expect((result.jobs[0] as PublicJobWithSourceProvider).sourceProvider).toBe(sourceProvider);
		}
	);

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'GET /migration/%s/jobs/:jobId keeps detail fetches provider-scoped',
		async (sourceProvider) => {
			const expected = publicJob({
				id: `${sourceProvider}-job`,
				sourceProvider,
				source: { name: `${sourceProvider}_products` }
			});
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getMigrationImportJob(sourceProvider, `${sourceProvider}/job`);

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/migration/${sourceProvider}/jobs/${sourceProvider}%2Fjob`,
				{
					method: 'GET',
					headers: AUTH_HEADERS
				}
			);
			expect(result).toEqual(expected);
			expect((result as PublicJobWithSourceProvider).sourceProvider).toBe(sourceProvider);
		}
	);

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'POST /migration/%s/jobs/:jobId/cancel keeps cancel requests provider-scoped',
		async (sourceProvider) => {
			const expected = publicJob({
				id: `${sourceProvider}-job`,
				sourceProvider,
				status: 'cancelling',
				source: { name: `${sourceProvider}_products` }
			});
			const fetch = mockFetch(202, expected);
			client.setFetch(fetch);
			const request: CancelAlgoliaImportJobRequest = {};

			const result = await client.cancelMigrationImportJob(
				sourceProvider,
				`${sourceProvider}/job`,
				request
			);

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/migration/${sourceProvider}/jobs/${sourceProvider}%2Fjob/cancel`,
				{
					method: 'POST',
					headers: AUTH_HEADERS,
					body: JSON.stringify(request)
				}
			);
			expect(result).toEqual(expected);
			expect((result as PublicJobWithSourceProvider).sourceProvider).toBe(sourceProvider);
		}
	);

	it.each(CLOSED_SOURCE_PROVIDERS)(
		'POST /migration/%s/jobs/:jobId/resume keeps resume credentials provider-scoped',
		async (sourceProvider) => {
			const expected = publicJob({
				id: `${sourceProvider}-job`,
				sourceProvider,
				status: 'resuming',
				source: { name: `${sourceProvider}_products` }
			});
			const fetch = mockFetch(202, expected);
			client.setFetch(fetch);
			const request: NeutralResumeRequest = { apiKey: `${sourceProvider}-resume-source-key` };

			const result = await client.resumeMigrationImportJob(
				sourceProvider,
				`${sourceProvider}/job`,
				request
			);

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/migration/${sourceProvider}/jobs/${sourceProvider}%2Fjob/resume`,
				{
					method: 'POST',
					headers: AUTH_HEADERS,
					body: JSON.stringify(request)
				}
			);
			expect(result).toEqual(expected);
			expect((result as PublicJobWithSourceProvider).sourceProvider).toBe(sourceProvider);
		}
	);

	it('keeps existing Algolia wrappers byte-identical to the current Algolia requests', async () => {
		const availabilityFetch = mockFetch(200, {
			available: true,
			message: 'Algolia migration is available.',
			capabilities: { cancel: true, resume: false, replace: true, preview: true, verify: false }
		});
		client.setFetch(availabilityFetch);
		await client.getAlgoliaMigrationAvailability();
		expect(serializedRequest(availabilityFetch)).toBe(
			`${BASE_URL}/migration/algolia/availability {"Content-Type":"application/json","Authorization":"Bearer my-jwt-token"} `
		);

		const listFetch = mockFetch(200, { items: [], nextCursor: null });
		client.setFetch(listFetch);
		await client.listAlgoliaSourceIndexes({
			appId: VOLATILE_SOURCE_CREDENTIALS.appId,
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey,
			cursor: 'opaque/source cursor',
			hitsPerPage: 100
		});
		expect(serializedRequest(listFetch)).toBe(
			`${BASE_URL}/migration/algolia/list-indexes {"Content-Type":"application/json","Authorization":"Bearer my-jwt-token"} {"appId":"ALGOLIA_APP_123","apiKey":"algolia-source-key","cursor":"opaque/source cursor","hitsPerPage":100}`
		);

		const eligibilityFetch = mockFetch(200, {
			phase: 'target',
			mode: 'create',
			provider: 'aws',
			target: { kind: 'create', region: 'us-east-1', name: 'fj_products' },
			eligibilityToken: 'target-token',
			expiresAt: '2026-07-18T10:06:00Z'
		});
		client.setFetch(eligibilityFetch);
		await client.checkAlgoliaDestinationEligibility({
			phase: 'target',
			mode: 'create',
			target: { region: 'us-east-1', name: 'fj_products' },
			eligibilityToken: 'provider-token'
		});
		expect(serializedRequest(eligibilityFetch)).toBe(
			`${BASE_URL}/migration/algolia/destination-eligibility {"Content-Type":"application/json","Authorization":"Bearer my-jwt-token"} {"phase":"target","mode":"create","target":{"region":"us-east-1","name":"fj_products"},"eligibilityToken":"provider-token"}`
		);

		const createFetch = mockFetch(202, publicJob());
		client.setFetch(createFetch);
		await client.createAlgoliaImportJob(
			{
				mode: 'create',
				appId: VOLATILE_SOURCE_CREDENTIALS.appId,
				apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey,
				sourceName: VOLATILE_SOURCE_CREDENTIALS.sourceName,
				target: { eligibilityToken: 'target-token' }
			},
			'import-idempotency-key'
		);
		expect(serializedRequest(createFetch)).toBe(
			`${BASE_URL}/migration/algolia/jobs {"Content-Type":"application/json","Authorization":"Bearer my-jwt-token","idempotency-key":"import-idempotency-key"} {"mode":"create","appId":"ALGOLIA_APP_123","apiKey":"algolia-source-key","sourceName":"source_products","target":{"eligibilityToken":"target-token"}}`
		);

		const historyFetch = mockFetch(200, { jobs: [], nextCursor: null });
		client.setFetch(historyFetch);
		await client.listAlgoliaImportJobs({ limit: 10, cursor: 'opaque-history-cursor' });
		expect(serializedRequest(historyFetch)).toBe(
			`${BASE_URL}/migration/algolia/jobs?limit=10&cursor=opaque-history-cursor {"Content-Type":"application/json","Authorization":"Bearer my-jwt-token"} `
		);

		const detailFetch = mockFetch(200, publicJob());
		client.setFetch(detailFetch);
		await client.getAlgoliaImportJob('job/with/slashes');
		expect(serializedRequest(detailFetch)).toBe(
			`${BASE_URL}/migration/algolia/jobs/job%2Fwith%2Fslashes {"Content-Type":"application/json","Authorization":"Bearer my-jwt-token"} `
		);

		const cancelFetch = mockFetch(202, publicJob({ status: 'cancelling' }));
		client.setFetch(cancelFetch);
		await client.cancelAlgoliaImportJob('job/with/slashes', {});
		expect(serializedRequest(cancelFetch)).toBe(
			`${BASE_URL}/migration/algolia/jobs/job%2Fwith%2Fslashes/cancel {"Content-Type":"application/json","Authorization":"Bearer my-jwt-token"} {}`
		);

		const resumeFetch = mockFetch(202, publicJob({ status: 'resuming' }));
		client.setFetch(resumeFetch);
		await client.resumeAlgoliaImportJob('job/with/slashes', {
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey
		});
		expect(serializedRequest(resumeFetch)).toBe(
			`${BASE_URL}/migration/algolia/jobs/job%2Fwith%2Fslashes/resume {"Content-Type":"application/json","Authorization":"Bearer my-jwt-token"} {"apiKey":"algolia-source-key"}`
		);
	});
});
