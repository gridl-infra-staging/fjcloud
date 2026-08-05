import { beforeEach, describe, expect, it } from 'vitest';
import { ApiClient, ApiRequestError } from './client';
import type {
	AlgoliaDestinationEligibilityRequest,
	AlgoliaDestinationEligibilityResponse,
	AlgoliaMigrationAvailabilityResponse,
	AlgoliaImportWarning,
	AlgoliaSourceListResponse,
	CancelAlgoliaImportJobRequest,
	CreateAlgoliaImportJobRequest,
	ListAlgoliaImportJobsRequest,
	ListAlgoliaIndexesRequest,
	PublicAlgoliaImportJobPage,
	ResumeAlgoliaImportJobRequest
} from './types';
import { BASE_URL, createAuthenticatedClient, mockFetch } from './client.test.shared';
import {
	AUTH_HEADERS,
	VOLATILE_SOURCE_CREDENTIALS,
	expectApiRequestError,
	expectNoAlgoliaCredentialBytes,
	expectRequestBody,
	fullSourceMetadata,
	mockFetchWithHeaders,
	publicJob,
	requestInit,
	requestJsonBody,
	serializedRequest
} from './client_migration_test_fixtures';

describe('ApiClient - migration availability', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createAuthenticatedClient();
	});

	it('GET /migration/algolia/availability returns the typed availability contract', async () => {
		const expected: AlgoliaMigrationAvailabilityResponse = {
			available: false,
			reason: 'temporarily_unavailable',
			message: 'Algolia migration is temporarily unavailable while we replace the importer.',
			capabilities: { cancel: false, resume: false, replace: false, preview: false, verify: false }
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.getAlgoliaMigrationAvailability();

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/migration/algolia/availability`, {
			method: 'GET',
			headers: AUTH_HEADERS
		});
		expect(result).toEqual(expected);
	});

	it('normalizes a payload with no capabilities to the all-false capability object', async () => {
		const wirePayload = {
			available: false,
			reason: 'temporarily_unavailable',
			message: 'Algolia migration is temporarily unavailable while we replace the importer.'
		};
		client.setFetch(mockFetch(200, wirePayload));

		const result = await client.getAlgoliaMigrationAvailability();

		expect(result.capabilities).toEqual({
			cancel: false,
			resume: false,
			replace: false,
			preview: false,
			verify: false
		});
	});

	it('accepts an available payload with no reason', async () => {
		const wirePayload = {
			available: true,
			message: 'Algolia migration is available.',
			capabilities: { cancel: true, resume: false, replace: true, preview: true, verify: false }
		};
		client.setFetch(mockFetch(200, wirePayload));

		const result = await client.getAlgoliaMigrationAvailability();

		expect(result).toEqual(wirePayload);
		expect('reason' in result).toBe(false);
	});

	it('normalizes preview capability to a required fail-closed boolean', async () => {
		const cases = [
			{
				name: 'wire preview true',
				wire: {
					available: true,
					message: 'Algolia migration is available.',
					capabilities: { cancel: true, resume: false, replace: true, preview: true, verify: false }
				},
				expected: {
					available: true,
					message: 'Algolia migration is available.',
					capabilities: { cancel: true, resume: false, replace: true, preview: true, verify: false }
				}
			},
			{
				name: 'omitted capabilities',
				wire: {
					available: false,
					reason: 'temporarily_unavailable',
					message: 'Algolia migration is temporarily unavailable.'
				},
				expected: {
					available: false,
					reason: 'temporarily_unavailable',
					message: 'Algolia migration is temporarily unavailable.',
					capabilities: {
						cancel: false,
						resume: false,
						replace: false,
						preview: false,
						verify: false
					}
				}
			},
			{
				name: 'omitted preview',
				wire: {
					available: true,
					message: 'Algolia migration is available.',
					capabilities: {
						cancel: true,
						resume: true,
						replace: false,
						preview: false,
						verify: false
					}
				},
				expected: {
					available: true,
					message: 'Algolia migration is available.',
					capabilities: {
						cancel: true,
						resume: true,
						replace: false,
						preview: false,
						verify: false
					}
				}
			},
			{
				name: 'malformed preview',
				wire: {
					available: true,
					message: 'Algolia migration is available.',
					capabilities: {
						cancel: true,
						resume: false,
						replace: true,
						preview: 'true',
						verify: false
					}
				},
				expected: {
					available: true,
					message: 'Algolia migration is available.',
					capabilities: {
						cancel: true,
						resume: false,
						replace: true,
						preview: false,
						verify: false
					}
				}
			}
		] as const;

		for (const { wire, expected } of cases) {
			client.setFetch(mockFetch(200, wire));

			await expect(client.getAlgoliaMigrationAvailability()).resolves.toEqual(expected);
		}
	});

	it('normalizes verify capability to a required fail-closed boolean', async () => {
		const cases = [
			{ name: 'wire verify true', wire: { verify: true }, expected: true },
			{ name: 'wire verify false', wire: { verify: false }, expected: false },
			{ name: 'omitted verify', wire: {}, expected: false },
			{ name: 'malformed verify', wire: { verify: 'true' }, expected: false },
			{ name: 'null verify', wire: { verify: null }, expected: false }
		] as const;

		for (const { name, wire, expected } of cases) {
			client.setFetch(
				mockFetch(200, {
					available: true,
					message: 'Algolia migration is available.',
					capabilities: { cancel: true, resume: false, replace: true, preview: true, ...wire }
				})
			);

			const result = await client.getAlgoliaMigrationAvailability();

			expect(result.capabilities.verify, name).toBe(expected);
		}
	});

	it('omits a nullable OpenAPI reason from the normalized response', async () => {
		const wirePayload = {
			available: true,
			reason: null,
			message: 'Algolia migration is available.',
			capabilities: { cancel: true, resume: false, replace: true, preview: true, verify: false }
		};
		client.setFetch(mockFetch(200, wirePayload));

		const result = await client.getAlgoliaMigrationAvailability();

		expect(result).toEqual({
			available: true,
			message: 'Algolia migration is available.',
			capabilities: { cancel: true, resume: false, replace: true, preview: true, verify: false }
		});
		expect('reason' in result).toBe(false);
	});

	it('normalizes a present-but-partial payload with an unknown capability without throwing', async () => {
		const wirePayload = {
			available: false,
			reason: 'temporarily_unavailable',
			message: 'Algolia migration is temporarily unavailable while we replace the importer.',
			capabilities: { cancel: true, futureAction: true }
		};
		client.setFetch(mockFetch(200, wirePayload));

		const result = await client.getAlgoliaMigrationAvailability();

		expect(result.capabilities).toMatchObject({ cancel: true, resume: false, replace: false });
	});

	it('fails closed when malformed capability values are returned on the wire', async () => {
		const wirePayload = {
			available: false,
			reason: 'temporarily_unavailable',
			message: 'Algolia migration is temporarily unavailable while we replace the importer.',
			capabilities: { cancel: 'false', resume: 1, replace: true }
		};
		client.setFetch(mockFetch(200, wirePayload));
		const result = await client.getAlgoliaMigrationAvailability();
		expect(result.capabilities).toEqual({
			cancel: false,
			resume: false,
			replace: true,
			preview: false,
			verify: false
		});
	});

	it('fails closed when the availability value is truthy but not boolean true', async () => {
		client.setFetch(
			mockFetch(200, {
				available: 'false',
				message: 'Malformed upstream availability.',
				capabilities: { cancel: true, resume: false, replace: true, preview: true, verify: false }
			})
		);
		const result = await client.getAlgoliaMigrationAvailability();
		expect(result.available).toBe(false);
	});

	it('omits absent/null source-list cursor and hitsPerPage values while preserving nextCursor', async () => {
		const expected = { items: [], nextCursor: 'opaque-next-cursor' };
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.listAlgoliaSourceIndexes({
			appId: VOLATILE_SOURCE_CREDENTIALS.appId,
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey,
			cursor: null,
			hitsPerPage: null
		});

		expectRequestBody(fetch, {
			appId: VOLATILE_SOURCE_CREDENTIALS.appId,
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey
		});
		expect(result.nextCursor).toBe('opaque-next-cursor');
	});

	it('returns the full source metadata page and opaque nextCursor from source discovery', async () => {
		const source = fullSourceMetadata();
		const expected: AlgoliaSourceListResponse = {
			items: [source],
			nextCursor: 'opaque.source.cursor/v1'
		};
		client.setFetch(mockFetch(200, expected));

		const result = await client.listAlgoliaSourceIndexes({
			appId: VOLATILE_SOURCE_CREDENTIALS.appId,
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey
		});

		expect(result).toEqual(expected);
		expect(result.items[0]).toEqual({
			name: 'source_products',
			entries: 1234,
			dataSize: 2048,
			fileSize: 4096,
			updatedAt: '2026-07-18T10:00:00Z',
			lastBuildTimeS: 17,
			pendingTask: false,
			primary: 'primary_products',
			replicas: ['source_products_price_asc']
		});
		expect(result.nextCursor).toBe('opaque.source.cursor/v1');
	});

	it.each([
		[400, 'invalid_algolia_credentials', 'invalid_credentials'],
		[
			403,
			'Algolia discovery requires listIndexes. Migration requires settings and browse; seeUnretrievableAttributes is optional.',
			'missing_source_permission'
		],
		[400, 'invalid_algolia_discovery_cursor', 'source_changed'],
		[400, 'source_catalog_too_large', 'source_catalog_too_large'],
		[503, 'algolia_discovery_unavailable', 'backend_unavailable']
	])('propagates typed source-list errors for %s %s', async (status, message, code) => {
		const body = { error: message, code };
		client.setFetch(mockFetch(status, body));

		await expect(
			client.listAlgoliaSourceIndexes({
				appId: VOLATILE_SOURCE_CREDENTIALS.appId,
				apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey
			})
		).rejects.toMatchObject({
			status,
			message,
			body
		});

		try {
			await client.listAlgoliaSourceIndexes({
				appId: VOLATILE_SOURCE_CREDENTIALS.appId,
				apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey
			});
		} catch (error) {
			expect(error).toBeInstanceOf(ApiRequestError);
			expect((error as ApiRequestError).body).toEqual(body);
		}
	});

	it('POST /migration/algolia/destination-eligibility replays target eligibility with only the eligibility token', async () => {
		const expected: AlgoliaDestinationEligibilityResponse = {
			phase: 'target',
			mode: 'create',
			provider: 'aws',
			target: { kind: 'create', region: 'us-east-1', name: 'fj_products' },
			eligibilityToken: 'target-token',
			expiresAt: '2026-07-18T10:06:00Z'
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.checkAlgoliaDestinationEligibility({
			phase: 'target',
			mode: 'create',
			target: { region: 'us-east-1', name: 'fj_products' },
			eligibilityToken: 'provider-token'
		});

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/migration/algolia/destination-eligibility`, {
			method: 'POST',
			headers: AUTH_HEADERS,
			body: JSON.stringify({
				phase: 'target',
				mode: 'create',
				target: { region: 'us-east-1', name: 'fj_products' },
				eligibilityToken: 'provider-token'
			})
		});
		expect(result).toEqual(expected);
	});

	it('returns the canonical public job fields without deriving lifecycle values locally', async () => {
		const warning: AlgoliaImportWarning = {
			code: 'unsupported_synonym_type',
			message: 'Skipped one synonym',
			resource: 'synonyms',
			pageIndex: 2,
			itemIndex: 5,
			jsonPath: '$.synonyms[5]'
		};
		const expected = publicJob({
			status: 'completed_with_warnings',
			error: { code: 'incompatible_data' },
			terminalOutcomeObserved: true,
			warnings: [warning],
			resumable: false,
			resumeProvenance: null,
			resumeDeadline: null,
			publicationDisposition: 'promoted'
		});
		client.setFetch(mockFetch(200, expected));

		const result = await client.getAlgoliaImportJob('11111111-1111-1111-1111-111111111111');

		expect(result).toEqual(expected);
	});

	it('exposes every migration request and response type through the canonical API barrel', () => {
		const sourceRequest: ListAlgoliaIndexesRequest = {
			appId: VOLATILE_SOURCE_CREDENTIALS.appId,
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey,
			cursor: 'opaque.source.cursor/v1',
			hitsPerPage: 100
		};
		const destinationEligibilityRequest: AlgoliaDestinationEligibilityRequest = {
			phase: 'provider',
			mode: 'create',
			target: { region: 'us-east-1', name: 'fj_products' }
		};
		const targetEligibilityResponse: AlgoliaDestinationEligibilityResponse = {
			phase: 'target',
			mode: 'create',
			provider: 'aws',
			target: { kind: 'create', region: 'us-east-1', name: 'fj_products' },
			eligibilityToken: 'target-token',
			expiresAt: '2026-07-18T10:06:00Z'
		};
		const createRequest: CreateAlgoliaImportJobRequest = {
			mode: 'create',
			appId: VOLATILE_SOURCE_CREDENTIALS.appId,
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey,
			sourceName: VOLATILE_SOURCE_CREDENTIALS.sourceName,
			target: { eligibilityToken: 'target-token' }
		};
		const historyRequest: ListAlgoliaImportJobsRequest = {
			limit: 200,
			cursor: 'opaque.job.cursor/v1'
		};
		const cancelRequest: CancelAlgoliaImportJobRequest = {};
		const resumeRequest: ResumeAlgoliaImportJobRequest = {
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey
		};
		const page: PublicAlgoliaImportJobPage = {
			jobs: [publicJob()],
			nextCursor: 'opaque.job.cursor/v1'
		};

		expect(sourceRequest).toEqual({
			appId: 'ALGOLIA_APP_123',
			apiKey: 'algolia-source-key',
			cursor: 'opaque.source.cursor/v1',
			hitsPerPage: 100
		});
		expect(destinationEligibilityRequest.eligibilityToken).toBeUndefined();
		expect(targetEligibilityResponse.eligibilityToken).toBe('target-token');
		expect(createRequest.target.eligibilityToken).toBe('target-token');
		expect(historyRequest.limit).toBe(200);
		expect(cancelRequest).toEqual({});
		expect(resumeRequest).toEqual({ apiKey: 'algolia-source-key' });
		expect(page.jobs[0]?.resumeProvenance).toBe('engine_checkpoint');
	});

	it.each([
		{
			name: 'list source indexes with bounded page and source cursor',
			response: { items: [fullSourceMetadata()], nextCursor: 'opaque.source.cursor/v2' },
			run: (api: ApiClient) =>
				api.listAlgoliaSourceIndexes({
					appId: VOLATILE_SOURCE_CREDENTIALS.appId,
					apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey,
					cursor: 'opaque/source cursor',
					hitsPerPage: 100
				}),
			expectedUrl: `${BASE_URL}/migration/algolia/list-indexes`,
			expectedInit: {
				method: 'POST',
				headers: AUTH_HEADERS,
				body: JSON.stringify({
					appId: VOLATILE_SOURCE_CREDENTIALS.appId,
					apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey,
					cursor: 'opaque/source cursor',
					hitsPerPage: 100
				})
			}
		},
		{
			name: 'check provider eligibility without a token',
			response: {
				phase: 'provider',
				mode: 'create',
				provider: 'aws',
				target: { kind: 'create', region: 'us-east-1', name: 'fj_products' },
				eligibilityToken: 'provider-token',
				expiresAt: '2026-07-18T10:05:00Z'
			},
			run: (api: ApiClient) =>
				api.checkAlgoliaDestinationEligibility({
					phase: 'provider',
					mode: 'create',
					target: { region: 'us-east-1', name: 'fj_products' }
				}),
			expectedUrl: `${BASE_URL}/migration/algolia/destination-eligibility`,
			expectedInit: {
				method: 'POST',
				headers: AUTH_HEADERS,
				body: JSON.stringify({
					phase: 'provider',
					mode: 'create',
					target: { region: 'us-east-1', name: 'fj_products' }
				})
			}
		},
		{
			name: 'create import job with idempotency header',
			response: publicJob(),
			run: (api: ApiClient) =>
				api.createAlgoliaImportJob(
					{
						mode: 'create',
						appId: VOLATILE_SOURCE_CREDENTIALS.appId,
						apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey,
						sourceName: VOLATILE_SOURCE_CREDENTIALS.sourceName,
						target: { eligibilityToken: 'target-token' }
					},
					'import-idempotency-key'
				),
			expectedUrl: `${BASE_URL}/migration/algolia/jobs`,
			expectedInit: {
				method: 'POST',
				headers: { ...AUTH_HEADERS, 'idempotency-key': 'import-idempotency-key' },
				body: JSON.stringify({
					mode: 'create',
					appId: VOLATILE_SOURCE_CREDENTIALS.appId,
					apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey,
					sourceName: VOLATILE_SOURCE_CREDENTIALS.sourceName,
					target: { eligibilityToken: 'target-token' }
				})
			}
		},
		{
			name: 'get import job with encoded job id',
			response: publicJob(),
			run: (api: ApiClient) => api.getAlgoliaImportJob('job/id with spaces'),
			expectedUrl: `${BASE_URL}/migration/algolia/jobs/job%2Fid%20with%20spaces`,
			expectedInit: { method: 'GET', headers: AUTH_HEADERS }
		},
		{
			name: 'list import jobs with bounded page and job cursor',
			response: { jobs: [publicJob()], nextCursor: 'opaque.job.cursor/v2' },
			run: (api: ApiClient) => api.listAlgoliaImportJobs({ limit: 200, cursor: 'job cursor/2' }),
			expectedUrl: `${BASE_URL}/migration/algolia/jobs?limit=200&cursor=job+cursor%2F2`,
			expectedInit: { method: 'GET', headers: AUTH_HEADERS }
		},
		{
			name: 'cancel import job with an empty producer body',
			response: publicJob({ cancelRequestedAt: '2026-07-18T10:02:00Z' }),
			run: (api: ApiClient) => api.cancelAlgoliaImportJob('job/id'),
			expectedUrl: `${BASE_URL}/migration/algolia/jobs/job%2Fid/cancel`,
			expectedInit: { method: 'POST', headers: AUTH_HEADERS, body: JSON.stringify({}) }
		},
		{
			name: 'resume import job with encoded job id',
			response: publicJob({ status: 'resuming', resumeCount: 3 }),
			run: (api: ApiClient) =>
				api.resumeAlgoliaImportJob('job/id', { apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey }),
			expectedUrl: `${BASE_URL}/migration/algolia/jobs/job%2Fid/resume`,
			expectedInit: {
				method: 'POST',
				headers: AUTH_HEADERS,
				body: JSON.stringify({ apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey })
			}
		}
	])(
		'uses the single ApiClient transport for $name',
		async ({ response, run, expectedUrl, expectedInit }) => {
			const fetch = mockFetch(200, response);
			client.setFetch(fetch);

			const result = await run(client);

			expect(fetch).toHaveBeenCalledWith(expectedUrl, expectedInit);
			expect(result).toEqual(response);
		}
	);

	it('omits an empty list-history query string', async () => {
		const expected: PublicAlgoliaImportJobPage = { jobs: [], nextCursor: null };
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.listAlgoliaImportJobs();

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/migration/algolia/jobs`, {
			method: 'GET',
			headers: AUTH_HEADERS
		});
		expect(result).toEqual(expected);
	});

	it('keeps volatile source credentials inside only the source-owned request bodies', async () => {
		const sourceFetch = mockFetch(200, { items: [], nextCursor: null });
		client.setFetch(sourceFetch);
		await client.listAlgoliaSourceIndexes({
			appId: VOLATILE_SOURCE_CREDENTIALS.appId,
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey
		});
		expect(requestJsonBody(sourceFetch)).toEqual({
			appId: VOLATILE_SOURCE_CREDENTIALS.appId,
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey
		});

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
		expect(requestJsonBody(createFetch)).toEqual({
			mode: 'create',
			appId: VOLATILE_SOURCE_CREDENTIALS.appId,
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey,
			sourceName: VOLATILE_SOURCE_CREDENTIALS.sourceName,
			target: { eligibilityToken: 'target-token' }
		});
		expect(requestInit(createFetch).headers).toMatchObject({
			'idempotency-key': 'import-idempotency-key'
		});

		const resumeFetch = mockFetch(202, publicJob({ status: 'resuming' }));
		client.setFetch(resumeFetch);
		await client.resumeAlgoliaImportJob('job/id', {
			apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey
		});
		expect(requestJsonBody(resumeFetch)).toEqual({ apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey });
		expect(serializedRequest(resumeFetch)).not.toContain(VOLATILE_SOURCE_CREDENTIALS.appId);
		expect(serializedRequest(resumeFetch)).not.toContain(VOLATILE_SOURCE_CREDENTIALS.sourceName);
	});

	it('keeps credential-free migration operations free of Algolia credential bytes', async () => {
		const providerFetch = mockFetch(200, {
			phase: 'provider',
			mode: 'create',
			provider: 'aws',
			target: { kind: 'create', region: 'us-east-1', name: 'fj_products' },
			eligibilityToken: 'provider-token',
			expiresAt: '2026-07-18T10:05:00Z'
		});
		client.setFetch(providerFetch);
		await client.checkAlgoliaDestinationEligibility({
			phase: 'provider',
			mode: 'create',
			target: { region: 'us-east-1', name: 'fj_products' }
		});
		expectNoAlgoliaCredentialBytes(providerFetch);

		const targetFetch = mockFetch(200, {
			phase: 'target',
			mode: 'create',
			provider: 'aws',
			target: { kind: 'create', region: 'us-east-1', name: 'fj_products' },
			eligibilityToken: 'target-token',
			expiresAt: '2026-07-18T10:06:00Z'
		});
		client.setFetch(targetFetch);
		await client.checkAlgoliaDestinationEligibility({
			phase: 'target',
			mode: 'create',
			target: { region: 'us-east-1', name: 'fj_products' },
			eligibilityToken: 'provider-token'
		});
		expectNoAlgoliaCredentialBytes(targetFetch);
		expect(requestJsonBody(targetFetch)).toMatchObject({ eligibilityToken: 'provider-token' });

		const getFetch = mockFetch(200, publicJob());
		client.setFetch(getFetch);
		await client.getAlgoliaImportJob('job/id');
		expectNoAlgoliaCredentialBytes(getFetch);

		const listFetch = mockFetch(200, { jobs: [publicJob()], nextCursor: null });
		client.setFetch(listFetch);
		await client.listAlgoliaImportJobs({ limit: 25, cursor: 'opaque.job.cursor/v1' });
		expectNoAlgoliaCredentialBytes(listFetch);

		const cancelFetch = mockFetch(202, publicJob());
		client.setFetch(cancelFetch);
		await client.cancelAlgoliaImportJob('job/id');
		expectNoAlgoliaCredentialBytes(cancelFetch);
		expect(requestJsonBody(cancelFetch)).toEqual({});
	});

	it.each([
		{
			name: 'eligibility',
			status: 400,
			body: { error: 'invalid_eligibility_token', code: 'destination_changed' },
			retryAfter: undefined,
			run: (api: ApiClient) =>
				api.checkAlgoliaDestinationEligibility({
					phase: 'target',
					mode: 'create',
					target: { region: 'us-east-1', name: 'fj_products' },
					eligibilityToken: 'tampered-token'
				})
		},
		{
			name: 'source discovery',
			status: 503,
			body: { error: 'algolia_discovery_unavailable', code: 'backend_unavailable' },
			retryAfter: '30',
			run: (api: ApiClient) =>
				api.listAlgoliaSourceIndexes({
					appId: VOLATILE_SOURCE_CREDENTIALS.appId,
					apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey
				})
		},
		{
			name: 'create',
			status: 400,
			body: { error: 'idempotency_key_required', code: 'destination_changed' },
			retryAfter: undefined,
			run: (api: ApiClient) =>
				api.createAlgoliaImportJob(
					{
						mode: 'create',
						appId: VOLATILE_SOURCE_CREDENTIALS.appId,
						apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey,
						sourceName: VOLATILE_SOURCE_CREDENTIALS.sourceName,
						target: { eligibilityToken: 'target-token' }
					},
					''
				)
		},
		{
			name: 'status',
			status: 404,
			body: { error: 'algolia_import_job_not_found' },
			retryAfter: undefined,
			run: (api: ApiClient) => api.getAlgoliaImportJob('11111111-1111-1111-1111-111111111111')
		},
		{
			name: 'history',
			status: 400,
			body: { error: 'invalid_list_cursor' },
			retryAfter: undefined,
			run: (api: ApiClient) => api.listAlgoliaImportJobs({ cursor: 'tampered-cursor' })
		},
		{
			name: 'cancel',
			status: 409,
			body: { error: 'cancel_not_permitted', code: 'cancel_not_permitted' },
			retryAfter: undefined,
			run: (api: ApiClient) => api.cancelAlgoliaImportJob('11111111-1111-1111-1111-111111111111')
		},
		{
			name: 'resume',
			status: 503,
			body: { error: 'backend_unavailable', code: 'backend_unavailable' },
			retryAfter: '30',
			run: (api: ApiClient) =>
				api.resumeAlgoliaImportJob('11111111-1111-1111-1111-111111111111', {
					apiKey: VOLATILE_SOURCE_CREDENTIALS.apiKey
				})
		}
	])('propagates shared ApiRequestError metadata for $name failures', async (testCase) => {
		const headers: Record<string, string> = { 'x-request-id': `req-${testCase.name}` };
		if (testCase.retryAfter) {
			headers['Retry-After'] = testCase.retryAfter;
		}
		client.setFetch(mockFetchWithHeaders(testCase.status, testCase.body, headers));

		await expectApiRequestError(() => testCase.run(client), {
			status: testCase.status,
			body: testCase.body,
			requestId: `req-${testCase.name}`,
			retryAfter: testCase.retryAfter
		});
	});
});
