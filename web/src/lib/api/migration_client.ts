import type {
	AlgoliaDestinationEligibilityRequest,
	AlgoliaDestinationEligibilityResponse,
	AlgoliaMigrationAvailabilityResponse,
	AlgoliaMigrationAvailabilityWire,
	AlgoliaSourceListResponse,
	CancelAlgoliaImportJobRequest,
	CreateAlgoliaImportJobRequest,
	CreateMigrationImportJobRequest,
	ListAlgoliaImportJobsRequest,
	ListAlgoliaIndexesRequest,
	ListMigrationSourceIndexesRequest,
	MigrationPreviewArguments,
	MigrationPreviewResponse,
	PublicAlgoliaImportJob,
	PublicAlgoliaImportJobPage,
	ResumeAlgoliaImportJobRequest,
	SourceProvider,
	VerifySourceMigrationRequest,
	VerifySourceMigrationResponse
} from './types';
import { ApiRequestError } from './api_request_error';
import { BaseClient } from './base-client';
import {
	algoliaSourceListRequest,
	normalizeAlgoliaMigrationAvailability
} from './client_normalizers';
import { buildQueryString, pathSegment } from './client_paths';

const REDACTED_ERROR_VALUE = '[REDACTED]';
const SENSITIVE_ERROR_KEYS = new Set([
	'apikey',
	'appid',
	'applicationid',
	'authorization',
	'token',
	'secret',
	'password'
]);
const BEARER_TOKEN_PATTERN = /\bBearer\s+[A-Za-z0-9._~+/=-]+\b/gi;
const STRUCTURED_SECRET_PATTERN =
	/((?:api[_ -]?key|authorization|token|secret|password)["'\]]?\s*[:=]\s*["']?)([^"',\s}\]]+)/gi;

function isSensitiveErrorKey(key: string): boolean {
	return SENSITIVE_ERROR_KEYS.has(key.replace(/[^a-z0-9]/gi, '').toLowerCase());
}

function sanitizeErrorString(value: string): string {
	return value
		.replace(BEARER_TOKEN_PATTERN, 'Bearer [REDACTED]')
		.replace(STRUCTURED_SECRET_PATTERN, `$1${REDACTED_ERROR_VALUE}`);
}

function sanitizeErrorPayload(value: unknown): unknown {
	if (typeof value === 'string') {
		return sanitizeErrorString(value);
	}
	if (Array.isArray(value)) {
		return value.map((entry) => sanitizeErrorPayload(entry));
	}
	if (value && typeof value === 'object') {
		return Object.fromEntries(
			Object.entries(value as Record<string, unknown>).map(([key, entry]) => [
				key,
				isSensitiveErrorKey(key) ? REDACTED_ERROR_VALUE : sanitizeErrorPayload(entry)
			])
		);
	}
	return value;
}

/** Shared authenticated transport plus the migration API surface. */
export class MigrationClient extends BaseClient {
	private readonly token?: string;

	constructor(baseUrl: string, token?: string) {
		super(baseUrl);
		this.token = token;
	}

	protected authHeaders(): Record<string, string> {
		if (this.token) {
			return { Authorization: `Bearer ${this.token}` };
		}
		return {};
	}

	protected async handleErrorResponse(res: Response): Promise<never> {
		const data = sanitizeErrorPayload(await res.json().catch(() => ({ error: 'unknown error' })));
		const headers = res.headers ? new Headers(res.headers) : undefined;
		const requestId = headers?.get('x-request-id') ?? undefined;
		const message =
			data && typeof data === 'object' && typeof (data as { error?: unknown }).error === 'string'
				? (data as { error: string }).error
				: 'unknown error';
		throw new ApiRequestError(res.status, message, {
			// Backend x-request-id is operator-facing correlation metadata. It is
			// stored for logs/reporting, not rendered directly to customers.
			requestId,
			headers,
			body: data
		});
	}

	protected api<T>(
		method: string,
		path: string,
		body?: unknown,
		options?: { includeAuth?: boolean; headers?: Record<string, string> }
	): Promise<T> {
		const init: RequestInit = { method, headers: options?.headers };
		if (body !== undefined) {
			init.body = JSON.stringify(body);
		}
		return this.request<T>(path, init, options);
	}

	getAlgoliaMigrationAvailability(): Promise<AlgoliaMigrationAvailabilityResponse> {
		return this.getMigrationAvailability('algolia');
	}

	getMigrationAvailability(
		sourceProvider: SourceProvider
	): Promise<AlgoliaMigrationAvailabilityResponse> {
		return this.api('GET', `/migration/${pathSegment(sourceProvider)}/availability`).then(
			(payload) =>
				normalizeAlgoliaMigrationAvailability(payload as AlgoliaMigrationAvailabilityWire)
		);
	}

	listAlgoliaSourceIndexes(request: ListAlgoliaIndexesRequest): Promise<AlgoliaSourceListResponse> {
		return this.listMigrationSourceIndexes('algolia', algoliaSourceListRequest(request));
	}

	listMigrationSourceIndexes(
		sourceProvider: SourceProvider,
		request: ListMigrationSourceIndexesRequest
	): Promise<AlgoliaSourceListResponse> {
		return this.api('POST', `/migration/${pathSegment(sourceProvider)}/list-indexes`, request);
	}

	checkAlgoliaDestinationEligibility(
		request: AlgoliaDestinationEligibilityRequest
	): Promise<AlgoliaDestinationEligibilityResponse> {
		return this.checkMigrationDestinationEligibility('algolia', request);
	}

	checkMigrationDestinationEligibility(
		sourceProvider: SourceProvider,
		request: AlgoliaDestinationEligibilityRequest
	): Promise<AlgoliaDestinationEligibilityResponse> {
		return this.api(
			'POST',
			`/migration/${pathSegment(sourceProvider)}/destination-eligibility`,
			request
		);
	}

	createAlgoliaImportJob(
		request: CreateAlgoliaImportJobRequest,
		idempotencyKey: string
	): Promise<PublicAlgoliaImportJob> {
		return this.createMigrationImportJob('algolia', request, idempotencyKey);
	}

	createMigrationImportJob(
		sourceProvider: SourceProvider,
		request: CreateMigrationImportJobRequest,
		idempotencyKey: string
	): Promise<PublicAlgoliaImportJob> {
		return this.api('POST', `/migration/${pathSegment(sourceProvider)}/jobs`, request, {
			headers: { 'idempotency-key': idempotencyKey }
		});
	}

	/**
	 * Report-only preview of what an import would do. Advisory: it allocates no
	 * import job and no create idempotency key, so it deliberately sends no
	 * `idempotency-key` header — only `createMigrationImportJob` does.
	 *
	 * Provider-neutral by design: there is exactly one preview method and the
	 * provider stays in the path, matching every other migration seam here.
	 */
	previewMigrationImport(
		...[sourceProvider, request]: MigrationPreviewArguments
	): Promise<MigrationPreviewResponse> {
		return this.api('POST', `/migration/${pathSegment(sourceProvider)}/preview`, request);
	}

	verifySourceMigration(
		sourceProvider: SourceProvider,
		request: VerifySourceMigrationRequest
	): Promise<VerifySourceMigrationResponse> {
		return this.api('POST', `/migration/${pathSegment(sourceProvider)}/verify`, request);
	}

	getAlgoliaImportJob(jobId: string): Promise<PublicAlgoliaImportJob> {
		return this.getMigrationImportJob('algolia', jobId);
	}

	getMigrationImportJob(
		sourceProvider: SourceProvider,
		jobId: string
	): Promise<PublicAlgoliaImportJob> {
		return this.api('GET', `/migration/${pathSegment(sourceProvider)}/jobs/${pathSegment(jobId)}`);
	}

	listAlgoliaImportJobs(
		request: ListAlgoliaImportJobsRequest = {}
	): Promise<PublicAlgoliaImportJobPage> {
		return this.listMigrationImportJobs('algolia', request);
	}

	listMigrationImportJobs(
		sourceProvider: SourceProvider,
		request: ListAlgoliaImportJobsRequest = {}
	): Promise<PublicAlgoliaImportJobPage> {
		const query = buildQueryString([
			['limit', request.limit],
			['cursor', request.cursor]
		]);
		return this.api('GET', `/migration/${pathSegment(sourceProvider)}/jobs${query}`);
	}

	cancelAlgoliaImportJob(
		jobId: string,
		request: CancelAlgoliaImportJobRequest = {}
	): Promise<PublicAlgoliaImportJob> {
		return this.cancelMigrationImportJob('algolia', jobId, request);
	}

	cancelMigrationImportJob(
		sourceProvider: SourceProvider,
		jobId: string,
		request: CancelAlgoliaImportJobRequest = {}
	): Promise<PublicAlgoliaImportJob> {
		return this.api(
			'POST',
			`/migration/${pathSegment(sourceProvider)}/jobs/${pathSegment(jobId)}/cancel`,
			request
		);
	}

	resumeAlgoliaImportJob(
		jobId: string,
		request: ResumeAlgoliaImportJobRequest
	): Promise<PublicAlgoliaImportJob> {
		return this.resumeMigrationImportJob('algolia', jobId, request);
	}

	resumeMigrationImportJob(
		sourceProvider: SourceProvider,
		jobId: string,
		request: ResumeAlgoliaImportJobRequest
	): Promise<PublicAlgoliaImportJob> {
		return this.api(
			'POST',
			`/migration/${pathSegment(sourceProvider)}/jobs/${pathSegment(jobId)}/resume`,
			request
		);
	}
}
