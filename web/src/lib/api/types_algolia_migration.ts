// Algolia migration API types extracted from types.ts to keep the barrel
// file under the 800-line size cap.

// Per-operation capability flags for an Algolia migration. Each flag reports
// whether the operation is capable end-to-end (both fjcloud route and engine
// support present). "Absent means false" is enforced at the client boundary by
// normalizeAlgoliaMigrationAvailability, so the normalized shape below always
// carries explicit booleans.
export interface AlgoliaMigrationCapabilities {
	cancel: boolean;
	resume: boolean;
	replace: boolean;
}

export interface AlgoliaMigrationAvailabilityResponse {
	available: boolean;
	reason: 'temporarily_unavailable';
	message: string;
	capabilities: AlgoliaMigrationCapabilities;
}

// Raw wire shape before normalization: the server may omit `capabilities`
// entirely or supply only some known flags. The client normalizer fills any
// omitted known flag with `false` (fail closed).
export interface AlgoliaMigrationAvailabilityWire {
	available: boolean;
	reason: 'temporarily_unavailable';
	message: string;
	capabilities?: Partial<AlgoliaMigrationCapabilities>;
}

export interface ListAlgoliaIndexesRequest {
	appId: string;
	apiKey: string;
	cursor?: string | null;
	hitsPerPage?: number | null;
}

export interface AlgoliaIndexMetadata {
	name: string;
	entries: number;
	dataSize: number;
	fileSize: number;
	updatedAt: string;
	lastBuildTimeS: number;
	pendingTask: boolean;
	primary: string | null;
	replicas: string[];
}

export interface AlgoliaSourceListResponse {
	items: AlgoliaIndexMetadata[];
	nextCursor: string | null;
}

export type AlgoliaMigrationDestinationMode = 'create' | 'replace';
export type AlgoliaMigrationEligibilityPhase = 'provider' | 'target';
export type AlgoliaMigrationProvider = 'aws';

export interface AlgoliaDestinationEligibilityTargetRequest {
	region: string;
	name: string;
}

export interface AlgoliaDestinationEligibilityRequest {
	phase: AlgoliaMigrationEligibilityPhase;
	mode: AlgoliaMigrationDestinationMode;
	target: AlgoliaDestinationEligibilityTargetRequest;
	eligibilityToken?: string;
}

export interface AlgoliaDestinationEligibilityTargetResponse {
	kind: AlgoliaMigrationDestinationMode;
	region: string;
	name: string;
}

export interface AlgoliaDestinationEligibilityResponse {
	phase: AlgoliaMigrationEligibilityPhase;
	mode: AlgoliaMigrationDestinationMode;
	provider: AlgoliaMigrationProvider;
	target: AlgoliaDestinationEligibilityTargetResponse;
	eligibilityToken: string;
	expiresAt: string;
}

export interface CreateAlgoliaImportJobTargetRequest {
	eligibilityToken: string;
}

export interface CreateAlgoliaImportJobRequest {
	mode: AlgoliaMigrationDestinationMode;
	appId: string;
	apiKey: string;
	sourceName: string;
	target: CreateAlgoliaImportJobTargetRequest;
}

export interface ListAlgoliaImportJobsRequest {
	limit?: number;
	cursor?: string;
}

/** Cancel takes an empty producer body; the job id travels in the path. */
export type CancelAlgoliaImportJobRequest = Record<string, never>;

export interface ResumeAlgoliaImportJobRequest {
	apiKey: string;
}

export type AlgoliaImportJobStatus =
	| 'queued'
	| 'validating_source'
	| 'copying_configuration'
	| 'copying_documents'
	| 'verifying'
	| 'promoting'
	| 'cancelling'
	| 'cancelled'
	| 'resuming'
	| 'completed'
	| 'completed_with_warnings'
	| 'failed'
	| 'interrupted';

export type AlgoliaImportPublicationDisposition =
	| 'not_started'
	| 'unchanged'
	| 'promoted'
	| 'unknown';

export interface PublicAlgoliaImportDestination {
	kind: AlgoliaMigrationDestinationMode;
	target: string;
	region: string;
}

export interface PublicAlgoliaImportSource {
	appId: string;
	name: string;
}

export interface PublicAlgoliaImportError {
	code:
		| 'invalid_credentials'
		| 'missing_source_permission'
		| 'source_not_found'
		| 'source_catalog_too_large'
		| 'destination_conflict'
		| 'quota_exceeded'
		| 'source_too_large'
		| 'insufficient_engine_storage'
		| 'destination_changed'
		| 'source_changed'
		| 'incompatible_data'
		| 'engine_upgrade_required'
		| 'migration_ha_not_supported'
		| 'migration_provider_unsupported'
		| 'backend_unavailable'
		| 'interrupted'
		| 'cancel_not_permitted'
		| 'not_resumable'
		| 'internal';
	message: string | null;
}

export interface AlgoliaImportSummary {
	documentsExpected: number;
	documentsImported: number;
	documentsRejected: number;
	settingsApplied: number;
	settingsUnsupported: number;
	synonymsExpected: number;
	synonymsImported: number;
	synonymsRejected: number;
	rulesExpected: number;
	rulesImported: number;
	rulesRejected: number;
}

export interface PublicAlgoliaImportJob {
	id: string;
	status: AlgoliaImportJobStatus;
	mode: AlgoliaMigrationDestinationMode;
	destination: PublicAlgoliaImportDestination;
	source: PublicAlgoliaImportSource;
	summary: AlgoliaImportSummary;
	warnings: unknown;
	error: PublicAlgoliaImportError | null;
	cancelRequestedAt: string | null;
	resumeProvenance: string | null;
	resumeDeadline: string | null;
	resumable: boolean;
	resumeCount: number;
	publicationDisposition: AlgoliaImportPublicationDisposition;
	createdAt: string;
	updatedAt: string;
}

export interface PublicAlgoliaImportJobPage {
	jobs: PublicAlgoliaImportJob[];
	nextCursor: string | null;
}
