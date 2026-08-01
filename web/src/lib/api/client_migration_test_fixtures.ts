import { expect, vi, type Mock } from 'vitest';
import { ApiClient, ApiRequestError } from './client';
import type {
	AlgoliaDestinationEligibilityRequest,
	AlgoliaDestinationEligibilityResponse,
	AlgoliaIndexMetadata,
	AlgoliaMigrationAvailabilityResponse,
	AlgoliaSourceListResponse,
	CancelAlgoliaImportJobRequest,
	CreateAlgoliaImportJobRequest,
	ListAlgoliaImportJobsRequest,
	ListAlgoliaIndexesRequest,
	PublicAlgoliaImportJob,
	PublicAlgoliaImportJobPage,
	ResumeAlgoliaImportJobRequest
} from './types';
import { mockFetch } from './client.test.shared';

export const AUTH_HEADERS = {
	'Content-Type': 'application/json',
	Authorization: 'Bearer my-jwt-token'
};
export const VOLATILE_SOURCE_CREDENTIALS = {
	appId: 'ALGOLIA_APP_123',
	apiKey: 'algolia-source-key',
	sourceName: 'source_products'
};
export const CLOSED_SOURCE_PROVIDERS = ['algolia', 'meilisearch', 'typesense'] as const;
export type SourceProvider = (typeof CLOSED_SOURCE_PROVIDERS)[number];
export type PublicJobWithSourceProvider = PublicAlgoliaImportJob & {
	sourceProvider: SourceProvider;
};
export type NeutralSourceListRequest =
	| (ListAlgoliaIndexesRequest & { source_provider?: never })
	| {
			host: string;
			apiKey: string;
			cursor?: string;
			hitsPerPage?: number;
	  };
export type NeutralCreateRequest =
	| (CreateAlgoliaImportJobRequest & { source_provider?: never })
	| {
			mode: 'create';
			host: string;
			apiKey: string;
			sourceName: string;
			target: { eligibilityToken: string };
	  };
export type NeutralResumeRequest = ResumeAlgoliaImportJobRequest;
export type NeutralMigrationClient = ApiClient & {
	getMigrationAvailability: (
		sourceProvider: SourceProvider
	) => Promise<AlgoliaMigrationAvailabilityResponse>;
	listMigrationSourceIndexes: (
		sourceProvider: SourceProvider,
		request: NeutralSourceListRequest
	) => Promise<AlgoliaSourceListResponse>;
	checkMigrationDestinationEligibility: (
		sourceProvider: SourceProvider,
		request: AlgoliaDestinationEligibilityRequest
	) => Promise<AlgoliaDestinationEligibilityResponse>;
	createMigrationImportJob: (
		sourceProvider: SourceProvider,
		request: NeutralCreateRequest,
		idempotencyKey: string
	) => Promise<PublicAlgoliaImportJob>;
	getMigrationImportJob: (
		sourceProvider: SourceProvider,
		jobId: string
	) => Promise<PublicAlgoliaImportJob>;
	listMigrationImportJobs: (
		sourceProvider: SourceProvider,
		request?: ListAlgoliaImportJobsRequest
	) => Promise<PublicAlgoliaImportJobPage>;
	cancelMigrationImportJob: (
		sourceProvider: SourceProvider,
		jobId: string,
		request?: CancelAlgoliaImportJobRequest
	) => Promise<PublicAlgoliaImportJob>;
	resumeMigrationImportJob: (
		sourceProvider: SourceProvider,
		jobId: string,
		request: NeutralResumeRequest
	) => Promise<PublicAlgoliaImportJob>;
};

export function neutralSourceListRequest(sourceProvider: SourceProvider): NeutralSourceListRequest {
	if (sourceProvider === 'algolia') {
		return {
			appId: 'ALGOLIA_NEUTRAL_APP',
			apiKey: 'algolia-neutral-source-key',
			cursor: 'algolia/cursor',
			hitsPerPage: 100
		};
	}
	return {
		host: `https://${sourceProvider}.example.test`,
		apiKey: `${sourceProvider}-neutral-source-key`,
		cursor: `${sourceProvider}/cursor`,
		hitsPerPage: 100
	};
}

export function neutralCreateRequest(sourceProvider: SourceProvider): NeutralCreateRequest {
	if (sourceProvider === 'algolia') {
		return {
			mode: 'create',
			appId: 'ALGOLIA_NEUTRAL_APP',
			apiKey: 'algolia-neutral-source-key',
			sourceName: 'algolia_products',
			target: { eligibilityToken: 'algolia-target-token' }
		};
	}
	return {
		mode: 'create',
		host: `https://${sourceProvider}.example.test`,
		apiKey: `${sourceProvider}-neutral-source-key`,
		sourceName: `${sourceProvider}_products`,
		target: { eligibilityToken: `${sourceProvider}-target-token` }
	};
}

export function expectRequestBody(fetch: ReturnType<typeof mockFetch>, expected: unknown): void {
	const init = (fetch as unknown as Mock).mock.calls[0]?.[1] as RequestInit | undefined;
	expect(init?.body).toBe(JSON.stringify(expected));
}

export function requestJsonBody(fetch: ReturnType<typeof mockFetch>, callIndex = 0): unknown {
	const body = requestInit(fetch, callIndex).body;
	expect(typeof body).toBe('string');
	return JSON.parse(body as string);
}

export function requestInit(fetch: ReturnType<typeof mockFetch>, callIndex = 0): RequestInit {
	const init = (fetch as unknown as Mock).mock.calls[callIndex]?.[1] as RequestInit | undefined;
	expect(init).toBeDefined();
	return init as RequestInit;
}

export function requestUrl(fetch: ReturnType<typeof mockFetch>, callIndex = 0): string {
	const url = (fetch as unknown as Mock).mock.calls[callIndex]?.[0] as string | undefined;
	expect(url).toBeDefined();
	return url as string;
}

export function mockFetchWithHeaders(
	status: number,
	body: unknown,
	headers: Record<string, string>
): typeof globalThis.fetch {
	return vi.fn().mockResolvedValue({
		ok: status >= 200 && status < 300,
		status,
		headers: new Headers(headers),
		json: () => Promise.resolve(body)
	});
}

export function serializedRequest(fetch: ReturnType<typeof mockFetch>, callIndex = 0): string {
	const init = requestInit(fetch, callIndex);
	return `${requestUrl(fetch, callIndex)} ${JSON.stringify(init.headers)} ${String(init.body ?? '')}`;
}

export function expectNoAlgoliaCredentialBytes(
	fetch: ReturnType<typeof mockFetch>,
	callIndex = 0
): void {
	const serialized = serializedRequest(fetch, callIndex);
	for (const credential of [
		VOLATILE_SOURCE_CREDENTIALS.appId,
		VOLATILE_SOURCE_CREDENTIALS.apiKey,
		VOLATILE_SOURCE_CREDENTIALS.sourceName
	]) {
		expect(serialized).not.toContain(credential);
	}
}

export async function expectApiRequestError(
	action: () => Promise<unknown>,
	expected: {
		status: number;
		body: Record<string, unknown>;
		requestId: string;
		retryAfter?: string;
	}
): Promise<void> {
	try {
		await action();
		throw new Error('Expected ApiRequestError');
	} catch (error) {
		expect(error).toBeInstanceOf(ApiRequestError);
		const apiError = error as ApiRequestError;
		expect(apiError.status).toBe(expected.status);
		expect(apiError.message).toBe(expected.body.error);
		expect(apiError.body).toEqual(expected.body);
		expect(apiError.requestId).toBe(expected.requestId);
		expect(apiError.headers?.get('Retry-After') ?? undefined).toBe(expected.retryAfter);
	}
}

export function publicJob(
	overrides: Partial<PublicAlgoliaImportJob> & { sourceProvider?: SourceProvider } = {}
): PublicJobWithSourceProvider {
	return {
		id: '11111111-1111-1111-1111-111111111111',
		status: 'failed',
		mode: 'create',
		sourceProvider: 'algolia',
		destination: { kind: 'create', target: 'fj_products', region: 'us-east-1' },
		source: {
			name: VOLATILE_SOURCE_CREDENTIALS.sourceName
		},
		summary: {
			documentsExpected: 17,
			documentsImported: 13,
			documentsRejected: 4,
			settingsApplied: 1,
			settingsUnsupported: 2,
			synonymsExpected: 5,
			synonymsImported: 3,
			synonymsRejected: 2,
			rulesExpected: 7,
			rulesImported: 6,
			rulesRejected: 1
		},
		terminalOutcomeObserved: false,
		warnings: [],
		error: null,
		cancelRequestedAt: null,
		resumeProvenance: 'engine_checkpoint',
		resumeDeadline: '2026-07-18T11:02:00Z',
		resumable: true,
		resumeCount: 2,
		publicationDisposition: 'unchanged',
		createdAt: '2026-07-18T10:00:00Z',
		updatedAt: '2026-07-18T10:05:00Z',
		...overrides
	} as PublicJobWithSourceProvider;
}

export function fullSourceMetadata(
	overrides: Partial<AlgoliaIndexMetadata> = {}
): AlgoliaIndexMetadata {
	return {
		name: 'source_products',
		entries: 1234,
		dataSize: 2048,
		fileSize: 4096,
		updatedAt: '2026-07-18T10:00:00Z',
		lastBuildTimeS: 17,
		pendingTask: false,
		primary: 'primary_products',
		replicas: ['source_products_price_asc'],
		...overrides
	};
}
