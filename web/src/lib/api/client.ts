/**
 */
import type {
	AuthResponse,
	MessageResponse,
	RegisterRequest,
	LoginRequest,
	VerifyEmailRequest,
	ForgotPasswordRequest,
	ResetPasswordRequest,
	UsageSummaryResponse,
	DailyUsageEntry,
	InvoiceListItem,
	InvoiceDetailResponse,
	EstimatedBillResponse,
	SetupIntentResponse,
	CreateBillingPortalSessionRequest,
	CreateBillingPortalSessionResponse,
	PaymentMethod,
	ApiKeyListItem,
	CreateApiKeyRequest,
	CreateApiKeyResponse,
	CustomerProfileResponse,
	AccountExportResponse,
	UpdateProfileRequest,
	ChangePasswordRequest,
	AybInstance,
	CreateAybInstanceRequest,
	Index,
	CreateIndexResponse,
	SearchResult,
	AddObjectsRequest,
	AddObjectsResponse,
	BrowseObjectsRequest,
	BrowseObjectsResponse,
	CreateIndexKeyRequest,
	InternalRegion,
	IndexReplicaSummary,
	OnboardingStatus,
	FlapjackCredentials,
	FlapjackApiKey,
	Rule,
	RuleSearchResponse,
	Synonym,
	SynonymType,
	SynonymSearchResponse,
	PersonalizationStrategy,
	PersonalizationProfile,
	RecommendationsBatchRequest,
	RecommendationsBatchResponse,
	IndexChatRequest,
	IndexChatResponse,
	QsConfig,
	QsBuildStatus,
	AnalyticsTopSearchesResponse,
	AnalyticsSearchCountResponse,
	AnalyticsNoResultRateResponse,
	AnalyticsDateRangeParams,
	AnalyticsStatusResponse,
	ConcludeExperimentRequest,
	CreateExperimentRequest,
	Experiment,
	ExperimentActionResponse,
	ExperimentListResponse,
	ExperimentResults,
	DebugEventsResponse,
	DebugEventsFilters,
	DictionaryLanguagesResponse,
	DictionarySearchRequest,
	DictionarySearchResponse,
	DictionaryBatchRequest,
	DictionaryBatchResponse,
	SecuritySourcesResponse,
	PricingCompareRequest,
	PricingCompareResponse,
	AlgoliaListRequest,
	AlgoliaIndexListResponse,
	AlgoliaMigrateRequest,
	AlgoliaMigrateResponse
} from './types';
import { BaseClient } from './base-client';

export class ApiRequestError extends Error {
	constructor(
		public readonly status: number,
		message: string,
		public readonly metadata: { requestId?: string; headers?: Headers } = {}
	) {
		super(message);
		this.name = 'ApiRequestError';
	}

	get requestId(): string | undefined {
		return this.metadata.requestId;
	}

	get headers(): Headers | undefined {
		return this.metadata.headers;
	}
}

export class ApiClient extends BaseClient {
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
			headers
		});
	}

	private api<T>(
		method: string,
		path: string,
		body?: unknown,
		options?: { includeAuth?: boolean }
	): Promise<T> {
		const init: RequestInit = { method };
		if (body !== undefined) {
			init.body = JSON.stringify(body);
		}
		return this.request<T>(path, init, options);
	}

	private buildQueryString(entries: Array<[string, string | number | undefined]>): string {
		const params = new URLSearchParams();
		for (const [key, value] of entries) {
			if (value !== undefined) {
				params.set(key, String(value));
			}
		}
		const query = params.toString();
		return query ? `?${query}` : '';
	}

	private pathSegment(value: string | number): string {
		return encodeURIComponent(String(value));
	}

	private indexPath(indexName: string, suffix = ''): string {
		return `/indexes/${this.pathSegment(indexName)}${suffix}`;
	}

	private experimentPath(indexName: string, id: number | string, suffix = ''): string {
		return this.indexPath(indexName, `/experiments/${this.pathSegment(id)}${suffix}`);
	}

	private dictionaryPath(indexName: string, dictionaryName: string, suffix = ''): string {
		return this.indexPath(indexName, `/dictionaries/${this.pathSegment(dictionaryName)}${suffix}`);
	}

	// --- Public (no auth) ---

	healthCheck(): Promise<unknown> {
		return this.api('GET', '/health');
	}

	register(body: RegisterRequest): Promise<AuthResponse> {
		return this.api('POST', '/auth/register', body);
	}

	login(body: LoginRequest): Promise<AuthResponse> {
		return this.api('POST', '/auth/login', body);
	}

	verifyEmail(body: VerifyEmailRequest): Promise<MessageResponse> {
		return this.api('POST', '/auth/verify-email', body);
	}

	forgotPassword(body: ForgotPasswordRequest): Promise<MessageResponse> {
		return this.api('POST', '/auth/forgot-password', body);
	}

	resetPassword(body: ResetPasswordRequest): Promise<MessageResponse> {
		return this.api('POST', '/auth/reset-password', body);
	}

	comparePricing(workload: PricingCompareRequest): Promise<PricingCompareResponse> {
		return this.api('POST', '/pricing/compare', workload, { includeAuth: false });
	}

	// --- Authenticated (tenant) ---

	getUsage(month?: string): Promise<UsageSummaryResponse> {
		return this.api('GET', `/usage${this.buildQueryString([['month', month]])}`);
	}

	getUsageDaily(month?: string): Promise<DailyUsageEntry[]> {
		return this.api('GET', `/usage/daily${this.buildQueryString([['month', month]])}`);
	}

	getInvoices(): Promise<InvoiceListItem[]> {
		return this.api('GET', '/invoices');
	}

	getInvoice(invoiceId: string): Promise<InvoiceDetailResponse> {
		return this.api('GET', `/invoices/${this.pathSegment(invoiceId)}`);
	}

	// --- Billing ---

	getEstimatedBill(month?: string): Promise<EstimatedBillResponse> {
		return this.api('GET', `/billing/estimate${this.buildQueryString([['month', month]])}`);
	}

	createSetupIntent(): Promise<SetupIntentResponse> {
		return this.api('POST', '/billing/setup-intent');
	}

	getPaymentMethods(): Promise<PaymentMethod[]> {
		return this.api('GET', '/billing/payment-methods');
	}

	deletePaymentMethod(pmId: string): Promise<void> {
		return this.api('DELETE', `/billing/payment-methods/${this.pathSegment(pmId)}`);
	}

	setDefaultPaymentMethod(pmId: string): Promise<void> {
		return this.api('POST', `/billing/payment-methods/${this.pathSegment(pmId)}/default`);
	}

	createBillingPortalSession(
		req: CreateBillingPortalSessionRequest
	): Promise<CreateBillingPortalSessionResponse> {
		return this.api('POST', '/billing/portal', req);
	}

	// --- API Keys ---

	createApiKey(req: CreateApiKeyRequest): Promise<CreateApiKeyResponse> {
		return this.api('POST', '/api-keys', req);
	}

	getApiKeys(): Promise<ApiKeyListItem[]> {
		return this.api('GET', '/api-keys');
	}

	deleteApiKey(id: string): Promise<void> {
		return this.api('DELETE', `/api-keys/${this.pathSegment(id)}`);
	}

	// --- Account ---

	getProfile(): Promise<CustomerProfileResponse> {
		return this.api('GET', '/account');
	}

	exportAccount(): Promise<AccountExportResponse> {
		return this.api('GET', '/account/export');
	}

	updateProfile(req: UpdateProfileRequest): Promise<CustomerProfileResponse> {
		return this.api('PATCH', '/account', req);
	}

	changePassword(req: ChangePasswordRequest): Promise<void> {
		return this.api('POST', '/account/change-password', req);
	}

	deleteAccount(password: string): Promise<void> {
		return this.api('DELETE', '/account', { password });
	}

	// --- AllYourBase Instances ---

	getAybInstances(): Promise<AybInstance[]> {
		return this.api('GET', '/allyourbase/instances');
	}

	deleteAybInstance(id: string): Promise<void> {
		return this.api('DELETE', `/allyourbase/instances/${this.pathSegment(id)}`);
	}

	createAybInstance(body: CreateAybInstanceRequest): Promise<AybInstance> {
		return this.api('POST', '/allyourbase/instances', body);
	}

	// --- Indexes ---

	getIndexes(): Promise<Index[]> {
		return this.api('GET', '/indexes');
	}

	getInternalRegions(): Promise<InternalRegion[]> {
		return this.api('GET', '/internal/regions');
	}

	getIndex(name: string): Promise<Index> {
		return this.api('GET', this.indexPath(name));
	}

	createIndex(name: string, region: string): Promise<CreateIndexResponse> {
		return this.api('POST', '/indexes', { name, region });
	}

	deleteIndex(name: string): Promise<void> {
		return this.api('DELETE', this.indexPath(name), { confirm: true });
	}

	testSearch(indexName: string, params: Record<string, unknown>): Promise<SearchResult> {
		return this.api('POST', this.indexPath(indexName, '/search'), params);
	}

	addObjects(indexName: string, requestBody: AddObjectsRequest): Promise<AddObjectsResponse> {
		return this.api('POST', this.indexPath(indexName, '/batch'), requestBody);
	}

	browseObjects(
		indexName: string,
		requestBody: BrowseObjectsRequest = {}
	): Promise<BrowseObjectsResponse> {
		return this.api('POST', this.indexPath(indexName, '/browse'), requestBody);
	}

	getObject(indexName: string, objectID: string): Promise<Record<string, unknown>> {
		return this.api('GET', this.indexPath(indexName, `/objects/${this.pathSegment(objectID)}`));
	}

	deleteObject(indexName: string, objectID: string): Promise<Record<string, unknown>> {
		return this.api('DELETE', this.indexPath(indexName, `/objects/${this.pathSegment(objectID)}`));
	}

	getIndexSettings(indexName: string): Promise<Record<string, unknown>> {
		return this.api('GET', this.indexPath(indexName, '/settings'));
	}

	updateIndexSettings(
		indexName: string,
		settings: Record<string, unknown>
	): Promise<Record<string, unknown>> {
		return this.api('PUT', this.indexPath(indexName, '/settings'), settings);
	}

	searchRules(
		indexName: string,
		query = '',
		page = 0,
		hitsPerPage = 50
	): Promise<RuleSearchResponse> {
		return this.api('POST', this.indexPath(indexName, '/rules/search'), {
			query,
			page,
			hitsPerPage
		});
	}

	saveRule(indexName: string, objectID: string, rule: Rule): Promise<Record<string, unknown>> {
		return this.api('PUT', this.indexPath(indexName, `/rules/${this.pathSegment(objectID)}`), rule);
	}

	getRule(indexName: string, objectID: string): Promise<Rule> {
		return this.api('GET', this.indexPath(indexName, `/rules/${this.pathSegment(objectID)}`));
	}

	deleteRule(indexName: string, objectID: string): Promise<Record<string, unknown>> {
		return this.api('DELETE', this.indexPath(indexName, `/rules/${this.pathSegment(objectID)}`));
	}

	/**
	 * TODO: Document ApiClient.searchSynonyms.
	 */
	searchSynonyms(
		indexName: string,
		query = '',
		synonymType?: SynonymType,
		page = 0,
		hitsPerPage = 50
	): Promise<SynonymSearchResponse> {
		const body: {
			query: string;
			page: number;
			hitsPerPage: number;
			type?: SynonymType;
		} = { query, page, hitsPerPage };
		if (synonymType) {
			body.type = synonymType;
		}

		return this.api('POST', this.indexPath(indexName, '/synonyms/search'), body);
	}

	saveSynonym(
		indexName: string,
		objectID: string,
		synonym: Synonym
	): Promise<Record<string, unknown>> {
		return this.api(
			'PUT',
			this.indexPath(indexName, `/synonyms/${this.pathSegment(objectID)}`),
			synonym
		);
	}

	getSynonym(indexName: string, objectID: string): Promise<Synonym> {
		return this.api('GET', this.indexPath(indexName, `/synonyms/${this.pathSegment(objectID)}`));
	}

	deleteSynonym(indexName: string, objectID: string): Promise<Record<string, unknown>> {
		return this.api(
			'DELETE',
			this.indexPath(indexName, `/synonyms/${encodeURIComponent(objectID)}`)
		);
	}

	getPersonalizationStrategy(indexName: string): Promise<PersonalizationStrategy> {
		return this.api('GET', this.indexPath(indexName, '/personalization/strategy'));
	}

	savePersonalizationStrategy(
		indexName: string,
		strategy: PersonalizationStrategy
	): Promise<Record<string, unknown>> {
		return this.api('PUT', this.indexPath(indexName, '/personalization/strategy'), strategy);
	}

	deletePersonalizationStrategy(indexName: string): Promise<Record<string, unknown>> {
		return this.api('DELETE', this.indexPath(indexName, '/personalization/strategy'));
	}

	getPersonalizationProfile(indexName: string, userToken: string): Promise<PersonalizationProfile> {
		return this.api(
			'GET',
			this.indexPath(indexName, `/personalization/profiles/${this.pathSegment(userToken)}`)
		);
	}

	deletePersonalizationProfile(
		indexName: string,
		userToken: string
	): Promise<Record<string, unknown>> {
		return this.api(
			'DELETE',
			this.indexPath(indexName, `/personalization/profiles/${this.pathSegment(userToken)}`)
		);
	}

	recommend(
		indexName: string,
		requestBody: RecommendationsBatchRequest
	): Promise<RecommendationsBatchResponse> {
		return this.api('POST', this.indexPath(indexName, '/recommendations'), requestBody);
	}

	chat(indexName: string, requestBody: IndexChatRequest): Promise<IndexChatResponse> {
		return this.api('POST', this.indexPath(indexName, '/chat'), requestBody);
	}

	getQsConfig(indexName: string): Promise<QsConfig> {
		return this.api('GET', this.indexPath(indexName, '/suggestions'));
	}

	saveQsConfig(indexName: string, config: QsConfig): Promise<Record<string, unknown>> {
		return this.api('PUT', this.indexPath(indexName, '/suggestions'), config);
	}

	deleteQsConfig(indexName: string): Promise<Record<string, unknown>> {
		return this.api('DELETE', this.indexPath(indexName, '/suggestions'));
	}

	getQsStatus(indexName: string): Promise<QsBuildStatus> {
		return this.api('GET', this.indexPath(indexName, '/suggestions/status'));
	}

	private analyticsQuery(params?: AnalyticsDateRangeParams): string {
		if (!params) return '';
		return this.buildQueryString([
			['startDate', params.startDate || undefined],
			['endDate', params.endDate || undefined],
			['limit', params.limit]
		]);
	}

	getAnalyticsTopSearches(
		indexName: string,
		params?: AnalyticsDateRangeParams
	): Promise<AnalyticsTopSearchesResponse> {
		return this.api(
			'GET',
			this.indexPath(indexName, `/analytics/searches${this.analyticsQuery(params)}`)
		);
	}

	getAnalyticsSearchCount(
		indexName: string,
		params?: AnalyticsDateRangeParams
	): Promise<AnalyticsSearchCountResponse> {
		return this.api(
			'GET',
			this.indexPath(indexName, `/analytics/searches/count${this.analyticsQuery(params)}`)
		);
	}

	getAnalyticsNoResults(
		indexName: string,
		params?: AnalyticsDateRangeParams
	): Promise<AnalyticsTopSearchesResponse> {
		return this.api(
			'GET',
			this.indexPath(indexName, `/analytics/searches/noResults${this.analyticsQuery(params)}`)
		);
	}

	getAnalyticsNoResultRate(
		indexName: string,
		params?: AnalyticsDateRangeParams
	): Promise<AnalyticsNoResultRateResponse> {
		return this.api(
			'GET',
			this.indexPath(indexName, `/analytics/searches/noResultRate${this.analyticsQuery(params)}`)
		);
	}

	getAnalyticsStatus(indexName: string): Promise<AnalyticsStatusResponse> {
		return this.api('GET', this.indexPath(indexName, '/analytics/status'));
	}

	listExperiments(indexName: string): Promise<ExperimentListResponse> {
		return this.api('GET', this.indexPath(indexName, '/experiments'));
	}

	createExperiment(
		indexName: string,
		requestBody: CreateExperimentRequest
	): Promise<ExperimentActionResponse> {
		return this.api('POST', this.indexPath(indexName, '/experiments'), requestBody);
	}

	getExperiment(indexName: string, id: number | string): Promise<Experiment> {
		return this.api('GET', this.experimentPath(indexName, id));
	}

	updateExperiment(
		indexName: string,
		id: number | string,
		requestBody: Record<string, unknown>
	): Promise<ExperimentActionResponse> {
		return this.api('PUT', this.experimentPath(indexName, id), requestBody);
	}

	deleteExperiment(indexName: string, id: number | string): Promise<ExperimentActionResponse> {
		return this.api('DELETE', this.experimentPath(indexName, id));
	}

	startExperiment(indexName: string, id: number | string): Promise<ExperimentActionResponse> {
		return this.api('POST', this.experimentPath(indexName, id, '/start'));
	}

	stopExperiment(indexName: string, id: number | string): Promise<ExperimentActionResponse> {
		return this.api('POST', this.experimentPath(indexName, id, '/stop'));
	}

	concludeExperiment(
		indexName: string,
		id: number | string,
		requestBody: ConcludeExperimentRequest
	): Promise<ExperimentActionResponse> {
		return this.api('POST', this.experimentPath(indexName, id, '/conclude'), requestBody);
	}

	getExperimentResults(indexName: string, id: number | string): Promise<ExperimentResults> {
		return this.api('GET', this.experimentPath(indexName, id, '/results'));
	}

	getDebugEvents(indexName: string, filters?: DebugEventsFilters): Promise<DebugEventsResponse> {
		const query = filters
			? this.buildQueryString([
					['eventType', filters.eventType || undefined],
					['status', filters.status || undefined],
					['limit', filters.limit],
					['from', filters.from],
					['until', filters.until]
				])
			: '';
		return this.api('GET', this.indexPath(indexName, `/events/debug${query}`));
	}

	// --- Dictionaries ---

	getDictionaryLanguages(indexName: string): Promise<DictionaryLanguagesResponse> {
		return this.api('GET', this.indexPath(indexName, '/dictionaries/languages'));
	}

	searchDictionaryEntries(
		indexName: string,
		dictionaryName: string,
		body: DictionarySearchRequest
	): Promise<DictionarySearchResponse> {
		return this.api('POST', this.dictionaryPath(indexName, dictionaryName, '/search'), body);
	}

	batchDictionaryEntries(
		indexName: string,
		dictionaryName: string,
		body: DictionaryBatchRequest
	): Promise<DictionaryBatchResponse> {
		return this.api('POST', this.dictionaryPath(indexName, dictionaryName, '/batch'), body);
	}

	// --- Security Sources ---

	getSecuritySources(indexName: string): Promise<SecuritySourcesResponse> {
		return this.api('GET', this.indexPath(indexName, '/security/sources'));
	}

	appendSecuritySource(
		indexName: string,
		body: { source: string; description: string }
	): Promise<Record<string, unknown>> {
		return this.api('POST', this.indexPath(indexName, '/security/sources'), body);
	}

	deleteSecuritySource(indexName: string, source: string): Promise<Record<string, unknown>> {
		return this.api(
			'DELETE',
			this.indexPath(indexName, `/security/sources/${this.pathSegment(source)}`)
		);
	}

	createIndexKey(indexName: string, description: string, acl: string[]): Promise<FlapjackApiKey> {
		return this.api('POST', this.indexPath(indexName, '/keys'), {
			description,
			acl
		} as CreateIndexKeyRequest);
	}

	// --- Index Replicas ---

	listReplicas(indexName: string): Promise<IndexReplicaSummary[]> {
		return this.api('GET', this.indexPath(indexName, '/replicas'));
	}

	createReplica(indexName: string, region: string): Promise<IndexReplicaSummary> {
		return this.api('POST', this.indexPath(indexName, '/replicas'), { region });
	}

	deleteReplica(indexName: string, replicaId: string): Promise<void> {
		return this.api(
			'DELETE',
			this.indexPath(indexName, `/replicas/${this.pathSegment(replicaId)}`)
		);
	}

	// --- Algolia Migration ---

	listAlgoliaIndexes(body: AlgoliaListRequest): Promise<AlgoliaIndexListResponse> {
		return this.api('POST', '/migration/algolia/list-indexes', body);
	}

	migrateFromAlgolia(body: AlgoliaMigrateRequest): Promise<AlgoliaMigrateResponse> {
		return this.api('POST', '/migration/algolia/migrate', body);
	}

	// --- Onboarding ---

	getOnboardingStatus(): Promise<OnboardingStatus> {
		return this.api('GET', '/onboarding/status');
	}

	generateCredentials(): Promise<FlapjackCredentials> {
		return this.api('POST', '/onboarding/credentials');
	}
}
