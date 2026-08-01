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
	PublicAlgoliaImportJob,
	PublicAlgoliaImportJobPage,
	ResumeAlgoliaImportJobRequest,
	SourceProvider
} from './types';
import { ApiRequestError } from './api_request_error';
import { BaseClient } from './base-client';
import {
	algoliaSourceListRequest,
	normalizeAlgoliaMigrationAvailability
} from './client_normalizers';
import { buildQueryString, pathSegment } from './client_paths';

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
		const data = await res.json().catch(() => ({ error: 'unknown error' }));
		const headers = res.headers ? new Headers(res.headers) : undefined;
		const requestId = headers?.get('x-request-id') ?? undefined;
		throw new ApiRequestError(res.status, data.error ?? 'unknown error', {
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
