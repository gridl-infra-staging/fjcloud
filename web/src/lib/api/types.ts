/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/lib/api/types.ts.
 */
// API response and request types matching the Axum API

export interface AuthResponse {
	token: string;
	customer_id: string;
}

export interface MessageResponse {
	message: string;
}

export interface RegisterRequest {
	name: string;
	email: string;
	password: string;
}

export interface LoginRequest {
	email: string;
	password: string;
}

export interface VerifyEmailRequest {
	token: string;
}

export interface ForgotPasswordRequest {
	email: string;
}

export interface ResetPasswordRequest {
	token: string;
	new_password: string;
}

export interface RegionUsageSummary {
	region: string;
	search_requests: number;
	write_operations: number;
	avg_storage_gb: number;
	avg_document_count: number;
}

export interface UsageSummaryResponse {
	month: string;
	total_search_requests: number;
	total_write_operations: number;
	avg_storage_gb: number;
	avg_document_count: number;
	by_region: RegionUsageSummary[];
}

export interface DailyUsageEntry {
	date: string;
	region: string;
	search_requests: number;
	write_operations: number;
	storage_gb: number;
	document_count: number;
}

export interface InvoiceListItem {
	id: string;
	period_start: string;
	period_end: string;
	subtotal_cents: number;
	total_cents: number;
	status: string;
	minimum_applied: boolean;
	created_at: string;
}

export interface LineItemResponse {
	id: string;
	description: string;
	quantity: string;
	unit: string;
	unit_price_cents: string;
	amount_cents: number;
	region: string;
}

export interface InvoiceDetailResponse {
	id: string;
	customer_id: string;
	period_start: string;
	period_end: string;
	subtotal_cents: number;
	total_cents: number;
	tax_cents: number;
	currency: string;
	status: string;
	minimum_applied: boolean;
	stripe_invoice_id: string | null;
	hosted_invoice_url: string | null;
	pdf_url: string | null;
	line_items: LineItemResponse[];
	created_at: string;
	finalized_at: string | null;
	paid_at: string | null;
}

export interface EstimateLineItem {
	description: string;
	quantity: string;
	unit: string;
	unit_price_cents: string;
	amount_cents: number;
	region: string;
}

export interface EstimatedBillResponse {
	month: string;
	subtotal_cents: number;
	total_cents: number;
	line_items: EstimateLineItem[];
	minimum_applied: boolean;
}

export interface SetupIntentResponse {
	client_secret: string;
}

export interface CreateBillingPortalSessionRequest {
	return_url: string;
}

export interface CreateBillingPortalSessionResponse {
	portal_url: string;
}

export interface PaymentMethod {
	id: string;
	card_brand: string;
	last4: string;
	exp_month: number;
	exp_year: number;
	is_default: boolean;
}

export interface SubscriptionResponse {
	id: string;
	plan_tier: string;
	status: string;
	current_period_end: string;
	cancel_at_period_end: boolean;
}

// API Key types
export interface ApiKeyListItem {
	id: string;
	name: string;
	key_prefix: string;
	scopes: string[];
	last_used_at: string | null;
	created_at: string;
}

export interface CreateApiKeyRequest {
	name: string;
	scopes: string[];
}

export interface CreateApiKeyResponse {
	id: string;
	name: string;
	key: string;
	key_prefix: string;
	scopes: string[];
	created_at: string;
}

// Account settings types
export interface CustomerProfileResponse {
	id: string;
	name: string;
	email: string;
	email_verified: boolean;
	billing_plan: 'free' | 'shared';
	created_at: string;
}

export interface AccountExportResponse {
	profile: CustomerProfileResponse;
}

export interface UpdateProfileRequest {
	name: string;
}

export interface ChangePasswordRequest {
	current_password: string;
	new_password: string;
}

// Index types (Stage 5 — customer-facing index management)
export interface Index {
	name: string;
	region: string;
	endpoint: string | null;
	entries: number;
	data_size_bytes: number;
	status: string;
	tier: string;
	created_at: string;
}

export interface CreateIndexRequest {
	name: string;
	region: string;
}

export interface InternalRegion {
	id: string;
	provider: string;
	provider_location: string;
	display_name: string;
	available: boolean;
}

export type CreateIndexResponse = Index;

export interface SearchResult {
	hits: unknown[];
	nbHits: number;
	processingTimeMs?: number;
	/** Extra metadata forwarded from the search engine (page, hitsPerPage, facets, etc.). */
	[key: string]: unknown;
}

export type DocumentBatchAction =
	| 'addObject'
	| 'updateObject'
	| 'deleteObject'
	| 'partialUpdateObject';

export interface DocumentBatchOperation {
	action: DocumentBatchAction;
	indexName?: string;
	body?: Record<string, unknown>;
	createIfNotExists?: boolean;
}

export interface AddObjectsRequest {
	requests: DocumentBatchOperation[];
}

export interface AddObjectsResponse {
	taskID: number;
	objectIDs?: string[];
	[key: string]: unknown;
}

export interface BrowseObjectsRequest {
	cursor?: string;
	query?: string;
	filters?: string;
	hitsPerPage?: number;
	attributesToRetrieve?: string[];
	params?: string;
}

export interface BrowseObjectsResponse {
	hits: Record<string, unknown>[];
	cursor: string | null;
	nbHits: number;
	page: number;
	nbPages: number;
	hitsPerPage: number;
	query: string;
	params: string;
	[key: string]: unknown;
}

export interface RuleCondition {
	pattern?: string;
	anchoring?: string;
	alternatives?: boolean;
	context?: string;
	filters?: string;
	[key: string]: unknown;
}

export interface RuleConsequence {
	promote?: Record<string, unknown>[];
	hide?: Record<string, unknown>[];
	filterPromotes?: boolean;
	userData?: Record<string, unknown>;
	params?: Record<string, unknown>;
	[key: string]: unknown;
}

export interface RuleValidityRange {
	from: number;
	until: number;
}

export interface Rule {
	objectID: string;
	conditions: RuleCondition[];
	consequence: RuleConsequence;
	description?: string;
	enabled?: boolean;
	validity?: RuleValidityRange[];
}

export interface RuleSearchResponse {
	hits: Rule[];
	nbHits: number;
	page: number;
	nbPages: number;
}

export type SynonymType =
	| 'synonym'
	| 'onewaysynonym'
	| 'altcorrection1'
	| 'altcorrection2'
	| 'placeholder';

export interface SynonymBase {
	objectID: string;
	type: SynonymType;
}

export interface MultiWaySynonym extends SynonymBase {
	type: 'synonym';
	synonyms: string[];
}

export interface OneWaySynonym extends SynonymBase {
	type: 'onewaysynonym';
	input: string;
	synonyms: string[];
}

export interface AltCorrection1Synonym extends SynonymBase {
	type: 'altcorrection1';
	word: string;
	corrections: string[];
}

export interface AltCorrection2Synonym extends SynonymBase {
	type: 'altcorrection2';
	word: string;
	corrections: string[];
}

export interface PlaceholderSynonym extends SynonymBase {
	type: 'placeholder';
	placeholder: string;
	replacements: string[];
}

export type Synonym =
	| MultiWaySynonym
	| OneWaySynonym
	| AltCorrection1Synonym
	| AltCorrection2Synonym
	| PlaceholderSynonym;

export interface SynonymSearchResponse {
	hits: Synonym[];
	nbHits: number;
}

export interface PersonalizationEventScoring {
	eventName: string;
	eventType: 'click' | 'conversion' | 'view';
	score: number;
}

export interface PersonalizationFacetScoring {
	facetName: string;
	score: number;
}

export interface PersonalizationStrategy {
	eventsScoring: PersonalizationEventScoring[];
	facetsScoring: PersonalizationFacetScoring[];
	personalizationImpact: number;
}

export interface PersonalizationProfile {
	userToken: string;
	lastEventAt?: string | null;
	scores: Record<string, Record<string, number>>;
}

export interface RecommendationRequest {
	indexName: string;
	model: string;
	objectID?: string;
	threshold?: number;
	maxRecommendations?: number;
	facetName?: string;
	facetValue?: string;
	queryParameters?: Record<string, unknown>;
	fallbackParameters?: Record<string, unknown>;
}

export interface RecommendationsBatchRequest {
	requests: RecommendationRequest[];
}

export interface RecommendationsResult {
	hits: Record<string, unknown>[];
	processingTimeMS: number;
}

export interface RecommendationsBatchResponse {
	results: RecommendationsResult[];
}

export interface IndexChatRequest {
	query: string;
	model?: string;
	conversationHistory?: Record<string, unknown>[];
	conversationId?: string;
}

export interface IndexChatResponse {
	answer: string;
	sources: Record<string, unknown>[];
	conversationId: string;
	queryID: string;
}

export interface QsFacet {
	attribute: string;
	amount: number;
}

export interface QsSourceIndex {
	indexName: string;
	minHits: number;
	minLetters: number;
	facets: QsFacet[];
	generate: string[][];
	analyticsTags: string[];
	replicas: boolean;
}

export interface QsConfig {
	indexName: string;
	sourceIndices: QsSourceIndex[];
	languages: string[];
	exclude: string[];
	allowSpecialCharacters: boolean;
	enablePersonalization: boolean;
}

export interface QsBuildStatus {
	indexName: string;
	isRunning: boolean;
	lastBuiltAt: string | null;
	lastSuccessfulBuiltAt: string | null;
}

export interface AnalyticsTopSearch {
	search: string;
	count: number;
	nbHits: number;
}

export interface AnalyticsTopSearchesResponse {
	searches: AnalyticsTopSearch[];
}

export interface AnalyticsDateCount {
	date: string;
	count: number;
}

export interface AnalyticsSearchCountResponse {
	count: number;
	dates: AnalyticsDateCount[];
}

export interface AnalyticsNoResultRateDateEntry {
	date: string;
	rate: number | null;
	count: number;
	noResults: number;
}

export interface AnalyticsNoResultRateResponse {
	rate: number | null;
	count: number;
	noResults: number;
	dates: AnalyticsNoResultRateDateEntry[];
}

export interface AnalyticsDateRangeParams {
	startDate?: string;
	endDate?: string;
	limit?: number;
}

export interface AnalyticsStatusResponse {
	indexName: string;
	enabled: boolean;
}

export interface ExperimentVariant {
	index: string;
	trafficPercentage: number;
	description?: string;
	customSearchParameters?: Record<string, unknown>;
	searchCount?: number;
	trackedSearchCount?: number;
	clickCount?: number;
	clickThroughRate?: number;
	conversionCount?: number;
	conversionRate?: number;
	noResultCount?: number;
	userCount?: number;
}

export interface ExperimentConfiguration {
	minimumDetectableEffect?: { size: number };
	outliers?: { exclude: boolean };
	emptySearch?: { exclude: boolean };
}

export interface Experiment {
	abTestID: number;
	name: string;
	status: string;
	endAt: string;
	createdAt: string;
	updatedAt: string;
	stoppedAt?: string;
	variants: ExperimentVariant[];
	configuration: ExperimentConfiguration;
}

export interface ExperimentListResponse {
	abtests: Experiment[];
	count: number;
	total: number;
}

export interface ExperimentActionResponse {
	abTestID: number;
	index: string;
	taskID: number;
}

export interface CreateExperimentRequest {
	name: string;
	variants: Array<{
		index: string;
		trafficPercentage: number;
		description?: string;
		customSearchParameters?: Record<string, unknown>;
	}>;
	configuration?: ExperimentConfiguration;
}

export interface ConcludeExperimentRequest {
	winner: 'control' | 'variant' | null;
	reason: string;
	controlMetric: number;
	variantMetric: number;
	confidence: number;
	significant: boolean;
	promoted: boolean;
}

export interface ExperimentGate {
	minimumNReached: boolean;
	minimumDaysReached: boolean;
	readyToRead: boolean;
	requiredSearchesPerArm: number;
	currentSearchesPerArm: number;
	progressPct: number;
	estimatedDaysRemaining?: number;
}

export interface ExperimentArm {
	name: string;
	searches: number;
	users: number;
	clicks: number;
	conversions: number;
	revenue: number;
	ctr: number;
	conversionRate: number;
	revenuePerSearch: number;
	zeroResultRate: number;
	abandonmentRate: number;
	meanClickRank: number;
}

export interface ExperimentSignificance {
	zScore: number;
	pValue: number;
	confidence: number;
	significant: boolean;
	relativeImprovement: number;
	winner?: string;
}

export interface ExperimentResults {
	experimentID: string;
	name: string;
	status: string;
	indexName: string;
	trafficSplit: number;
	gate: ExperimentGate;
	control: ExperimentArm;
	variant: ExperimentArm;
	primaryMetric: string;
	significance?: ExperimentSignificance;
	bayesian?: { probVariantBetter: number };
	sampleRatioMismatch: boolean;
	guardRailAlerts: Array<{
		metricName: string;
		controlValue: number;
		variantValue: number;
		dropPct: number;
	}>;
	cupedApplied: boolean;
	recommendation?: string;
	interleaving?: {
		deltaAB: number;
		winsControl: number;
		winsVariant: number;
		ties: number;
		pValue: number;
		significant: boolean;
		totalQueries: number;
		dataQualityOk: boolean;
	};
}

// Event debugger types (Stage 8)
export interface DebugEvent {
	timestampMs: number;
	index: string;
	eventType: string;
	eventSubtype: string | null;
	eventName: string;
	userToken: string;
	objectIds: string[];
	httpCode: number;
	validationErrors: string[];
}

export interface DebugEventsResponse {
	events: DebugEvent[];
	count: number;
}

export interface DebugEventsFilters {
	eventType?: string;
	status?: string;
	limit?: number;
	from?: number;
	until?: number;
}

export interface CreateIndexKeyRequest {
	description: string;
	acl: string[];
}

// Flapjack VM-side API key — returned by POST /indexes/:name/keys.
// Matches Rust FlapjackApiKey with #[serde(rename_all = "camelCase")].
// Different from FlapjackCredentials (returned by POST /onboarding/credentials).
export interface FlapjackApiKey {
	key: string;
	createdAt: string;
}

// Onboarding types
export interface OnboardingStatus {
	has_payment_method: boolean;
	has_region: boolean;
	region_ready: boolean;
	has_index: boolean;
	has_api_key: boolean;
	completed: boolean;
	billing_plan: 'free' | 'shared';
	free_tier_limits: FreeTierLimits | null;
	flapjack_url: string | null;
	suggested_next_step: string;
}

export interface FreeTierLimits {
	max_searches_per_month: number;
	max_records: number;
	max_storage_gb: number;
	max_indexes: number;
}

export interface FlapjackCredentials {
	endpoint: string;
	api_key: string;
	application_id: string;
}

// Index replica types (multi-region read replicas)
export interface IndexReplicaSummary {
	id: string;
	replica_region: string;
	status: string;
	lag_ops: number;
	endpoint: string;
	created_at: string;
}

export interface ApiError {
	error: string;
	status: number;
}

// Dictionary types (dictionary entry management)
// Dictionary types live in their own module to keep this barrel file
// under the size-limit gate. Consumers continue to import from
// `$lib/api/types` — the re-export preserves the public surface.
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

// Security Sources types
export interface SecuritySource {
	source: string;
	description: string;
}

export interface SecuritySourcesResponse {
	sources: SecuritySource[];
}

// Pricing comparison types live in their own module to keep this barrel
// file under the size-limit gate. Consumers continue to import from
// `$lib/api/types` — the re-export preserves the public surface.
export type {
	PricingCompareRequest,
	PricingCostLineItem,
	PricingEstimate,
	PricingCompareResponse
} from './types_pricing';

// Algolia migration types live in their own module to keep this barrel
// file under the size-limit gate. Consumers continue to import from
// `$lib/api/types` — the re-export preserves the public surface.
export type {
	AlgoliaIndexInfo,
	AlgoliaIndexListResponse,
	AlgoliaListRequest,
	AlgoliaMigrateRequest,
	AlgoliaMigrateResponse
} from './types_algolia_migration';
