// Algolia migration API types extracted from types.ts to keep the barrel
// file under the 800-line size cap.

// Per-operation capability flags for an Algolia migration. Each flag reports
// whether the operation is capable end-to-end (both fjcloud route and engine
// support present). "Absent means false" is enforced at the client boundary by
// normalizeAlgoliaMigrationAvailability, so the normalized shape below always
// carries explicit booleans.
export const SOURCE_PROVIDERS = ['algolia', 'meilisearch', 'typesense'] as const;
export type SourceProvider = (typeof SOURCE_PROVIDERS)[number];

export function isSourceProvider(value: unknown): value is SourceProvider {
	return typeof value === 'string' && (SOURCE_PROVIDERS as readonly string[]).includes(value);
}

export interface AlgoliaMigrationCapabilities {
	cancel: boolean;
	resume: boolean;
	replace: boolean;
	preview: boolean;
	verify: boolean;
}

export interface AlgoliaMigrationAvailabilityResponse {
	available: boolean;
	reason?: 'temporarily_unavailable';
	message: string;
	capabilities: AlgoliaMigrationCapabilities;
}

// Raw wire shape before normalization: the server may omit `capabilities`
// entirely, omit or null `reason` for available responses, or supply only some
// known capability flags. The client normalizer fills any omitted known flag
// with `false` (fail closed) and removes a null reason.
export interface AlgoliaMigrationAvailabilityWire {
	available: boolean;
	reason?: 'temporarily_unavailable' | null;
	message: string;
	capabilities?: Partial<AlgoliaMigrationCapabilities>;
}

export interface ListAlgoliaIndexesRequest {
	appId: string;
	apiKey: string;
	cursor?: string | null;
	hitsPerPage?: number | null;
}

export interface ListHostedSearchIndexesRequest {
	host: string;
	apiKey: string;
	cursor?: string | null;
	hitsPerPage?: number | null;
}

export type ListMigrationSourceIndexesRequest =
	| ListAlgoliaIndexesRequest
	| ListHostedSearchIndexesRequest;

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
	name?: string;
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

export interface CreateHostedSearchImportJobRequest {
	mode: AlgoliaMigrationDestinationMode;
	host: string;
	apiKey: string;
	sourceName: string;
	target: CreateAlgoliaImportJobTargetRequest;
}

export type CreateMigrationImportJobRequest =
	| CreateAlgoliaImportJobRequest
	| CreateHostedSearchImportJobRequest;

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
		| 'source_provider_unsupported'
		| 'backend_unavailable'
		| 'interrupted'
		| 'cancel_not_permitted'
		| 'not_resumable'
		| 'internal';
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

export interface AlgoliaImportWarning {
	code: string;
	message: string;
	resource: string;
	pageIndex: number | null;
	itemIndex: number | null;
	jsonPath: string;
}

export interface PublicAlgoliaImportJob {
	id: string;
	status: AlgoliaImportJobStatus;
	mode: AlgoliaMigrationDestinationMode;
	sourceProvider: SourceProvider;
	destination: PublicAlgoliaImportDestination;
	source: PublicAlgoliaImportSource;
	summary: AlgoliaImportSummary;
	terminalOutcomeObserved: boolean;
	warnings: AlgoliaImportWarning[];
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

// ---------------------------------------------------------------------------
// Report-only migration preview.
//
// Preview is advisory: it reports what an import would do and creates nothing.
// No import job, no create idempotency key, no durable state.
//
// Every type below mirrors `docs/reference/openapi.json` exactly. The closed
// value sets are exported as `as const` arrays so `src/tests/openapi-drift.test.ts`
// can pin both directions — a producer-side addition fails there rather than
// silently widening the console's vocabulary.
// ---------------------------------------------------------------------------

export interface AlgoliaMigrationPreviewRequest {
	appId: string;
	apiKey: string;
	sourceIndex: string;
	targetIndex?: string | null;
	overwrite?: boolean;
}

export interface MeilisearchMigrationPreviewRequest {
	endpoint: string;
	apiKey: string;
	sourceIndex: string;
	targetIndex?: string | null;
	overwrite?: boolean;
}

/**
 * `MigrationPreviewRequest` publishes only these two arms today because the
 * request body differs by provider. This union is only a request-body-shape
 * guard; runtime preview support is owned by `capabilities.preview` from the
 * provider-scoped availability response.
 */
export type MigrationPreviewRequest =
	| AlgoliaMigrationPreviewRequest
	| MeilisearchMigrationPreviewRequest;

export const MIGRATION_PREVIEW_SOURCE_PROVIDERS = ['algolia', 'meilisearch'] as const;
export type MigrationPreviewSourceProvider = (typeof MIGRATION_PREVIEW_SOURCE_PROVIDERS)[number];
export type MigrationPreviewArguments =
	| [sourceProvider: 'algolia', request: AlgoliaMigrationPreviewRequest]
	| [sourceProvider: 'meilisearch', request: MeilisearchMigrationPreviewRequest];

export const MIGRATION_PREVIEW_REPORT_SEVERITIES = [
	'ScopeGap',
	'Warning',
	'HardRejection'
] as const;
export type MigrationPreviewReportSeverity = (typeof MIGRATION_PREVIEW_REPORT_SEVERITIES)[number];

export const MIGRATION_PREVIEW_REPORT_RESOURCES = [
	'Analytics',
	'ApiKeys',
	'Document',
	'Events',
	'Experiments',
	'Recommend',
	'Rule',
	'Settings',
	'Synonym'
] as const;
export type MigrationPreviewReportResource = (typeof MIGRATION_PREVIEW_REPORT_RESOURCES)[number];

export const MIGRATION_PREVIEW_REPORT_CODES = [
	'ProductNotMigrated',
	'PersistedNoBehaviorSetting',
	'ReadOnlySourceField',
	'ReplicaTopologyNotMigrated',
	'UnsupportedSourceField',
	'UnsupportedRuleSchema',
	'UnsupportedSynonymSchema',
	'InvalidObjectId',
	'DuplicateObjectId',
	'MalformedSettingsPayload',
	'MalformedDocumentPayload',
	'MalformedRulePayload',
	'MalformedSynonymPayload',
	'ReplicaUnknownRankingToken',
	'ReplicaExhaustiveSortApproximated',
	'ReplicaPrimaryRelevancyStrictnessDropped',
	'ReplicaRelevancyStrictnessSemanticMismatch',
	'ReplicaMatchingCriticalFieldDiverges',
	'MeilisearchDocumentOrderNotContractual',
	'MeilisearchSearchPaginationNotExportBound',
	'MeilisearchSettingNotMigrated',
	'MeilisearchSettingValueNormalized',
	'TypesenseSettingNotMigrated'
] as const;
export type MigrationPreviewReportCode = (typeof MIGRATION_PREVIEW_REPORT_CODES)[number];

/**
 * A single translation finding. Unlike `AlgoliaImportWarning`, this carries a
 * `severity` and carries no customer-facing `message` — the engine publishes
 * neither a message here nor a severity there. Any presentation shared with the
 * retained-job warning model has to reconcile both differences in one owner
 * (`job_presentation.ts`), not by forking the renderer.
 */
export interface MigrationPreviewReportEntry {
	severity: MigrationPreviewReportSeverity;
	code: MigrationPreviewReportCode;
	resource: MigrationPreviewReportResource;
	pageIndex?: number | null;
	itemIndex?: number | null;
	jsonPath: string;
}

export interface MigrationPreviewReportSummary {
	totalEntries: number;
	hardRejections: number;
	warnings: number;
	scopeGaps: number;
}

export interface MigrationPreviewReport {
	entries: MigrationPreviewReportEntry[];
	summary: MigrationPreviewReportSummary;
	reportDigest?: string | null;
}

export interface MigrationPreviewSourceCounts {
	indexes: number;
	records: number;
}

export interface MigrationPreviewResponse {
	report: MigrationPreviewReport;
	sourceCounts: MigrationPreviewSourceCounts;
}

// ---------------------------------------------------------------------------
// Report-only source/destination cutover verification.
//
// This mirrors FS-7 exactly. It compares source and destination top-N objectID
// sets and ranks; it is not a verdict, score, threshold, or migration approval.
// ---------------------------------------------------------------------------

export interface VerifySourceMigrationRequest {
	appId: string;
	apiKey: string;
	sourceIndex: string;
	destinationIndex: string;
	queries: string[];
	resultLimit: number;
}

export interface VerifySourceMigrationHitComparison {
	objectID: string;
	sourceRank: number;
	destinationRank: number;
	rankDelta: number;
}

export interface VerifySourceMigrationQueryReport {
	query: string;
	overlapCount: number;
	sourceOnly: string[];
	destinationOnly: string[];
	hits: VerifySourceMigrationHitComparison[];
}

export interface VerifySourceMigrationResponse {
	sourceIndex: string;
	destinationIndex: string;
	resultLimit: number;
	queries: VerifySourceMigrationQueryReport[];
}
