/**
 * @module API response and request types matching the Axum API.
 *
 * This file is a pure re-export barrel. Type bodies live in focused per-domain
 * modules under ./types/ (created here) and in the flat sibling split owners
 * `./types_dictionary`, `./types_pricing`, and `./types_algolia_migration`.
 * Consumers continue to import from `$lib/api/types` — do not import from the
 * per-domain modules directly.
 */

export type { MessageResponse, MessageWithRetryAfterResponse, ApiError } from './types/common';

export type {
	AuthResponse,
	RegisterRequest,
	LoginRequest,
	VerifyEmailRequest,
	ForgotPasswordRequest,
	ResetPasswordRequest,
	OAuthExchangeRequest
} from './types/auth';

export type {
	RegionUsageSummary,
	UsageSummaryResponse,
	DailyUsageEntry,
	InvoiceListItem,
	LineItemResponse,
	InvoiceDetailResponse,
	EstimateLineItem,
	EstimatedBillResponse,
	SetupIntentResponse,
	CreateBillingPortalSessionRequest,
	CreateBillingPortalSessionResponse,
	PaymentMethod,
	BillingUpgradeResponse
} from './types/billing';

export type { ApiKeyListItem, CreateApiKeyRequest, CreateApiKeyResponse } from './types/api_keys';

export type {
	CustomerProfileResponse,
	CustomerUpgradeStatusResponse,
	AccountExportResponse,
	UpdateProfileRequest,
	ChangePasswordRequest
} from './types/account';

export type {
	Index,
	CreateIndexRequest,
	InternalRegion,
	CreateIndexResponse,
	SearchResult,
	PreviewEventRequest,
	DocumentBatchAction,
	DocumentBatchOperation,
	AddObjectsRequest,
	AddObjectsResponse,
	BrowseObjectsRequest,
	BrowseObjectsResponse,
	IndexReplicaSummary,
	IndexMetricsResponse,
	UtilizationBucket,
	HeadroomStatus,
	InfrastructurePrimary,
	InfrastructureReplica,
	InfrastructureFootprint,
	IndexInfrastructureResponse
} from './types/indexes';

export type {
	RuleCondition,
	RuleConsequence,
	RuleValidityRange,
	Rule,
	RuleSearchResponse
} from './types/rules';

export type {
	SynonymType,
	SynonymBase,
	MultiWaySynonym,
	OneWaySynonym,
	AltCorrection1Synonym,
	AltCorrection2Synonym,
	PlaceholderSynonym,
	Synonym,
	SynonymSearchResponse
} from './types/synonyms';

export type {
	PersonalizationEventScoring,
	PersonalizationFacetScoring,
	PersonalizationStrategy,
	PersonalizationProfile
} from './types/personalization';

export type {
	RecommendationRequest,
	RecommendationsBatchRequest,
	RecommendationsResult,
	RecommendationsBatchResponse
} from './types/recommendations';

export type { IndexChatRequest, IndexChatResponse } from './types/chat';

export type { QsFacet, QsSourceIndex, QsConfig, QsBuildStatus } from './types/query_suggestions';

export type {
	AnalyticsTopSearch,
	AnalyticsTopSearchesResponse,
	AnalyticsDateCount,
	AnalyticsSearchCountResponse,
	AnalyticsNoResultRateDateEntry,
	AnalyticsNoResultRateResponse,
	AnalyticsRequiredDateRangeParams,
	AnalyticsDateRangeParams,
	AnalyticsStatusResponse,
	AnalyticsCountByKey,
	AnalyticsDevices,
	AnalyticsDevicesResponse,
	AnalyticsCountriesResponse,
	AnalyticsFilterValuesResponse,
	AnalyticsConversionMetrics,
	AnalyticsConversionTrendPoint,
	AnalyticsConversionRateResponse,
	AnalyticsConversionKpiDelta,
	AnalyticsConversionSubtabPayload
} from './types/analytics';

export type {
	ExperimentVariant,
	ExperimentConfiguration,
	Experiment,
	ExperimentListResponse,
	ExperimentActionResponse,
	CreateExperimentRequest,
	ConcludeExperimentRequest,
	ExperimentGate,
	ExperimentArm,
	ExperimentSignificance,
	ExperimentConclusion,
	ExperimentResults
} from './types/experiments';

export type { DebugEvent, DebugEventsResponse, DebugEventsFilters } from './types/debug_events';

export type { CreateIndexKeyRequest, FlapjackApiKey } from './types/flapjack';

export type { OnboardingStatus, FreeTierLimits, FlapjackCredentials } from './types/onboarding';

export type { SecuritySource, SecuritySourcesResponse } from './types/security_sources';

export type {
	PublicRegionHealth,
	PublicRegionUtilization,
	PublicRegionInfrastructure,
	PublicInfrastructureOverall,
	PublicInfrastructureResponse
} from './types/public_infrastructure';

export type {
	DictionaryName,
	DictionaryCount,
	LanguageDictionaryCounts,
	DictionaryLanguagesResponse,
	DictionaryEntry,
	DictionarySearchRequest,
	DictionarySearchResponse,
	DictionaryBatchAction,
	DictionaryBatchOperation,
	DictionaryBatchRequest,
	DictionaryBatchResponse
} from './types_dictionary';

export type {
	PricingCompareRequest,
	PricingCostLineItem,
	PricingEstimate,
	PricingCompareResponse
} from './types_pricing';

export type {
	AlgoliaMigrationCapabilities,
	AlgoliaMigrationAvailabilityResponse,
	AlgoliaMigrationAvailabilityWire,
	ListAlgoliaIndexesRequest,
	AlgoliaIndexMetadata,
	AlgoliaSourceListResponse,
	AlgoliaMigrationDestinationMode,
	AlgoliaMigrationEligibilityPhase,
	AlgoliaMigrationProvider,
	AlgoliaDestinationEligibilityTargetRequest,
	AlgoliaDestinationEligibilityRequest,
	AlgoliaDestinationEligibilityTargetResponse,
	AlgoliaDestinationEligibilityResponse,
	CreateAlgoliaImportJobTargetRequest,
	CreateAlgoliaImportJobRequest,
	ListAlgoliaImportJobsRequest,
	CancelAlgoliaImportJobRequest,
	ResumeAlgoliaImportJobRequest,
	AlgoliaImportJobStatus,
	AlgoliaImportPublicationDisposition,
	PublicAlgoliaImportDestination,
	PublicAlgoliaImportSource,
	PublicAlgoliaImportError,
	AlgoliaImportSummary,
	PublicAlgoliaImportJob,
	PublicAlgoliaImportJobPage
} from './types_algolia_migration';
