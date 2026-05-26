<script lang="ts">
	import { browser } from '$app/environment';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { SvelteURLSearchParams } from 'svelte/reactivity';
	import { indexStatusBadgeColor, statusLabel } from '$lib/format';
	import type {
		AnalyticsNoResultRateResponse,
		AnalyticsSearchCountResponse,
		AnalyticsStatusResponse,
		AnalyticsTopSearchesResponse,
		BrowseObjectsResponse,
		DictionaryLanguagesResponse,
		DictionaryName,
		DictionarySearchResponse,
		DebugEventsResponse,
		ExperimentListResponse,
		ExperimentResults,
		Index,
		IndexChatResponse,
		IndexReplicaSummary,
		InternalRegion,
		PersonalizationProfile,
		PersonalizationStrategy,
		QsBuildStatus,
		QsConfig,
		RecommendationsBatchResponse,
		RuleSearchResponse,
		SearchResult,
		SecuritySourcesResponse,
		SynonymSearchResponse
	} from '$lib/api/types';
	import AnalyticsTab from './tabs/AnalyticsTab.svelte';
	import EventsTab from './tabs/EventsTab.svelte';
	import ExperimentsTab from './tabs/ExperimentsTab.svelte';
	import MerchandisingTab from './tabs/MerchandisingTab.svelte';
	import DocumentsTab from './tabs/DocumentsTab.svelte';
	import DictionariesTab from './tabs/DictionariesTab.svelte';
	import OverviewTab from './tabs/OverviewTab.svelte';
	import RulesTab from './tabs/RulesTab.svelte';
	import SettingsTab from './tabs/SettingsTab.svelte';
	import SuggestionsTab from './tabs/SuggestionsTab.svelte';
	import PersonalizationTab from './tabs/PersonalizationTab.svelte';
	import RecommendationsTab from './tabs/RecommendationsTab.svelte';
	import ChatTab from './tabs/ChatTab.svelte';
	import SearchPreviewTab from './tabs/SearchPreviewTab.svelte';
	import SecuritySourcesTab from './tabs/SecuritySourcesTab.svelte';
	import SynonymsTab from './tabs/SynonymsTab.svelte';
	import SearchLogPanel from './SearchLogPanel.svelte';
	import { deriveFormLogEntry, extractFormAction } from '$lib/api-logs/dashboard-instrumentation';
	import { appendLogEntry } from '$lib/api-logs/store';

	let { data, form: formResult } = $props();

	const emptyExperiments: ExperimentListResponse = {
		abtests: [],
		count: 0,
		total: 0
	};

	function normalizeExperiments(value: unknown): ExperimentListResponse {
		if (!value || typeof value !== 'object') {
			return emptyExperiments;
		}

		const record = value as Partial<ExperimentListResponse>;
		const abtests = Array.isArray(record.abtests) ? record.abtests : [];
		const count = typeof record.count === 'number' ? record.count : abtests.length;
		const total = typeof record.total === 'number' ? record.total : count;

		return {
			...record,
			abtests,
			count,
			total
		} as ExperimentListResponse;
	}

	const emptyDocuments: BrowseObjectsResponse = {
		hits: [],
		cursor: null,
		nbHits: 0,
		page: 0,
		nbPages: 0,
		hitsPerPage: 20,
		query: '',
		params: ''
	};

	const emptyDictionaryEntries: DictionarySearchResponse = {
		hits: [],
		nbHits: 0,
		page: 0,
		nbPages: 0
	};

	const emptyDictionaries: {
		languages: DictionaryLanguagesResponse | null;
		selectedDictionary: DictionaryName;
		selectedLanguage: string;
		entries: DictionarySearchResponse;
	} = {
		languages: null,
		selectedDictionary: 'stopwords',
		selectedLanguage: '',
		entries: emptyDictionaryEntries
	};

	const index: Index = $derived(data.index);
	const settings: Record<string, unknown> | null = $derived(data.settings ?? null);
	const replicas: IndexReplicaSummary[] = $derived(data.replicas ?? []);
	const regions: InternalRegion[] = $derived(data.regions ?? []);
	const rules: RuleSearchResponse | null = $derived(data.rules ?? null);
	const synonyms: SynonymSearchResponse | null = $derived(data.synonyms ?? null);
	const personalizationStrategy: PersonalizationStrategy | null = $derived(
		data.personalizationStrategy ?? null
	);
	const qsConfig: QsConfig | null = $derived(data.qsConfig ?? null);
	const qsStatus: QsBuildStatus | null = $derived(data.qsStatus ?? null);
	const searchCount: AnalyticsSearchCountResponse | null = $derived(data.searchCount ?? null);
	const noResultRate: AnalyticsNoResultRateResponse | null = $derived(data.noResultRate ?? null);
	const topSearches: AnalyticsTopSearchesResponse | null = $derived(data.topSearches ?? null);
	const noResults: AnalyticsTopSearchesResponse | null = $derived(data.noResults ?? null);
	const analyticsStatus: AnalyticsStatusResponse | null = $derived(data.analyticsStatus ?? null);
	const analyticsPeriod: '7d' | '30d' | '90d' = $derived(data.analyticsPeriod ?? '7d');
	const analyticsStartDate: string = $derived(data.analyticsStartDate ?? '');
	const analyticsEndDate: string = $derived(data.analyticsEndDate ?? '');
	const experiments: ExperimentListResponse = $derived(normalizeExperiments(data.experiments));
	const experimentResultsMap: Record<string, ExperimentResults> = $derived(
		data.experimentResults ?? {}
	);
	const documents: BrowseObjectsResponse = $derived(
		formResult?.documents ?? data.documents ?? emptyDocuments
	);
	const dictionaries = $derived(formResult?.dictionaries ?? data.dictionaries ?? emptyDictionaries);
	const securitySources: SecuritySourcesResponse = $derived(
		formResult?.securitySources ?? data.securitySources ?? { sources: [] }
	);
	const securitySourcesReloaded: boolean = $derived(formResult?.securitySourcesReloaded === true);
	const actionSecuritySourcesLoadError: string = $derived(
		formResult?.securitySourcesLoadError ?? ''
	);
	const securitySourcesLoadError: string = $derived(
		actionSecuritySourcesLoadError ||
			(securitySourcesReloaded ? '' : (data.securitySourcesLoadError ?? ''))
	);
	const loadedDebugEvents: DebugEventsResponse | null = $derived(data.debugEvents ?? null);
	const eventsLoadError: string = $derived(
		formResult?.refreshedEvents ? '' : (data.eventsLoadError ?? '')
	);
	const refreshedDebugEvents: DebugEventsResponse | null = $derived(
		formResult?.refreshedEvents ?? null
	);
	const debugEvents: DebugEventsResponse | null = $derived(
		refreshedDebugEvents ?? loadedDebugEvents
	);

	const analyticsUnavailable: boolean = $derived(
		analyticsStatus === null ||
			analyticsStatus.enabled !== true ||
			searchCount === null ||
			noResultRate === null ||
			topSearches === null ||
			noResults === null
	);

	const availableReplicaRegions: InternalRegion[] = $derived(
		regions.filter(
			(region) =>
				region.available &&
				region.id !== index.region &&
				!replicas.some(
					(replica) =>
						replica.replica_region === region.id &&
						replica.status !== 'failed' &&
						replica.status !== 'removing'
				)
		)
	);

	const searchResult: SearchResult | null = $derived(formResult?.searchResult ?? null);
	const searchQuery: string = $derived(formResult?.query ?? '');
	const searchError: string = $derived(formResult?.searchError ?? '');
	const personalizationProfile: PersonalizationProfile | null = $derived(
		formResult?.personalizationProfile ?? null
	);
	const recommendationsResponse: RecommendationsBatchResponse | null = $derived(
		formResult?.recommendationsResponse ?? null
	);
	const chatResponse: IndexChatResponse | null = $derived(formResult?.chatResponse ?? null);
	const chatQuery: string = $derived(formResult?.chatQuery ?? '');

	const replicaError: string = $derived(formResult?.replicaError ?? '');
	const deleteError: string = $derived(formResult?.deleteError ?? '');
	const settingsError: string = $derived(formResult?.settingsError ?? '');
	const ruleError: string = $derived(formResult?.ruleError ?? '');
	const synonymError: string = $derived(formResult?.synonymError ?? '');
	const personalizationError: string = $derived(formResult?.personalizationError ?? '');
	const recommendationsError: string = $derived(formResult?.recommendationsError ?? '');
	const chatError: string = $derived(formResult?.chatError ?? '');
	const qsConfigError: string = $derived(formResult?.qsConfigError ?? '');
	const experimentError: string = $derived(formResult?.experimentError ?? '');
	const eventsError: string = $derived(formResult?.eventsError ?? '');
	const documentsUploadError: string = $derived(formResult?.documentsUploadError ?? '');
	const documentsAddError: string = $derived(formResult?.documentsAddError ?? '');
	const documentsBrowseError: string = $derived(formResult?.documentsBrowseError ?? '');
	const documentsDeleteError: string = $derived(formResult?.documentsDeleteError ?? '');
	const dictionaryBrowseError: string = $derived(formResult?.dictionaryBrowseError ?? '');
	const dictionarySaveError: string = $derived(formResult?.dictionarySaveError ?? '');
	const dictionaryDeleteError: string = $derived(formResult?.dictionaryDeleteError ?? '');
	const securitySourceAppendError: string = $derived(formResult?.securitySourceAppendError ?? '');
	const securitySourceDeleteError: string = $derived(formResult?.securitySourceDeleteError ?? '');
	const previewKey: string = $derived(formResult?.previewKey ?? '');
	const previewKeyError: string = $derived(formResult?.previewKeyError ?? '');
	const previewIndexName: string = $derived(formResult?.previewIndexName ?? index.name);

	const replicaCreated: boolean = $derived(Boolean(formResult?.replicaCreated));
	const settingsSaved: boolean = $derived(Boolean(formResult?.settingsSaved));
	const ruleSaved: boolean = $derived(Boolean(formResult?.ruleSaved));
	const ruleDeleted: boolean = $derived(Boolean(formResult?.ruleDeleted));
	const synonymSaved: boolean = $derived(Boolean(formResult?.synonymSaved));
	const synonymDeleted: boolean = $derived(Boolean(formResult?.synonymDeleted));
	const personalizationStrategySaved: boolean = $derived(
		Boolean(formResult?.personalizationStrategySaved)
	);
	const personalizationStrategyDeleted: boolean = $derived(
		Boolean(formResult?.personalizationStrategyDeleted)
	);
	const personalizationProfileDeleted: boolean = $derived(
		Boolean(formResult?.personalizationProfileDeleted)
	);
	const qsConfigSaved: boolean = $derived(Boolean(formResult?.qsConfigSaved));
	const qsConfigDeleted: boolean = $derived(Boolean(formResult?.qsConfigDeleted));
	const documentsUploadSuccess: boolean = $derived(Boolean(formResult?.documentsUploadSuccess));
	const documentsAddSuccess: boolean = $derived(Boolean(formResult?.documentsAddSuccess));
	const documentsBrowseSuccess: boolean = $derived(Boolean(formResult?.documentsBrowseSuccess));
	const documentsDeleteSuccess: boolean = $derived(Boolean(formResult?.documentsDeleteSuccess));
	const dictionarySaved: boolean = $derived(Boolean(formResult?.dictionarySaved));
	const dictionaryDeleted: boolean = $derived(Boolean(formResult?.dictionaryDeleted));
	const securitySourceAppended: boolean = $derived(Boolean(formResult?.securitySourceAppended));
	const securitySourceDeleted: boolean = $derived(Boolean(formResult?.securitySourceDeleted));

	const TAB_DEFINITIONS = [
		{ id: 'overview', label: 'Overview' },
		{ id: 'settings', label: 'Settings' },
		{ id: 'documents', label: 'Documents' },
		{ id: 'dictionaries', label: 'Dictionaries' },
		{ id: 'rules', label: 'Rules' },
		{ id: 'synonyms', label: 'Synonyms' },
		{ id: 'personalization', label: 'Personalization' },
		{ id: 'recommendations', label: 'Recommendations' },
		{ id: 'chat', label: 'Chat' },
		{ id: 'suggestions', label: 'Suggestions' },
		{ id: 'analytics', label: 'Analytics' },
		{ id: 'merchandising', label: 'Merchandising' },
		{ id: 'experiments', label: 'Experiments' },
		{ id: 'events', label: 'Events' },
		{ id: 'security-sources', label: 'Security Sources' },
		{ id: 'search-preview', label: 'Search Preview' }
	] as const;

	type ActiveTab = (typeof TAB_DEFINITIONS)[number]['id'];
	const validTabIds = new Set<ActiveTab>(TAB_DEFINITIONS.map((tab) => tab.id));

	function parseTabFromUrl(currentUrl: URL): ActiveTab | null {
		const rawTab = currentUrl.searchParams.get('tab');
		if (!rawTab) return null;
		if (!validTabIds.has(rawTab as ActiveTab)) return null;
		return rawTab as ActiveTab;
	}

	function currentUrlHasWelcomeBanner(currentUrl: URL): boolean {
		return currentUrl.searchParams.get('welcome') === '1';
	}

	function buildWelcomeConsumedSearchPreviewUrl(currentUrl: URL): string {
		const nextUrl = new URL(currentUrl);
		nextUrl.searchParams.set('welcome', '0');
		nextUrl.searchParams.set('tab', 'search-preview');
		return `${nextUrl.pathname}?${nextUrl.searchParams.toString()}`;
	}

	const initialTab = parseTabFromUrl(page.url) ?? 'overview';
	let activeTab = $state<ActiveTab>(initialTab);
	let visitedTabs = $state<Record<ActiveTab, boolean>>(
		Object.fromEntries(TAB_DEFINITIONS.map((tab) => [tab.id, tab.id === initialTab])) as Record<
			ActiveTab,
			boolean
		>
	);
	let showWelcomeBanner = $state(currentUrlHasWelcomeBanner(page.url));

	let showSearchLog = $state(false);
	let lastSubmittedAction = $state<string | null>(null);
	let lastLoggedFormResult: Record<string, unknown> | null = null;

	$effect(() => {
		if (formResult?.deleted && browser) {
			goto(resolve('/console/indexes'));
		}
	});

	// Capture form-result log entries at the page boundary so the viewer stays pure.
	$effect(() => {
		if (!formResult) return;
		if (formResult === lastLoggedFormResult) return;
		lastLoggedFormResult = formResult;
		const entry = deriveFormLogEntry(formResult, lastSubmittedAction);
		if (!entry) return;
		appendLogEntry(entry);
	});

	function trackSubmittedPostAction(event: SubmitEvent) {
		lastSubmittedAction = extractFormAction(event);
	}

	function activateTab(tab: ActiveTab) {
		activeTab = tab;
		visitedTabs[tab] = true;
		if (browser) {
			const currentUrlTab = parseTabFromUrl(page.url);
			if (currentUrlTab === tab) {
				return;
			}

			const nextSearchParams = new SvelteURLSearchParams(page.url.searchParams);
			nextSearchParams.set('tab', tab);
			// Route path is resolved via SvelteKit; query is preserved/merged by design.
			// eslint-disable-next-line svelte/no-navigation-without-resolve
			void goto(`${page.url.pathname}?${nextSearchParams.toString()}`, {
				keepFocus: true,
				noScroll: true
			});
		}
	}

	function activateSearchPreviewFromWelcomeBanner() {
		showWelcomeBanner = false;
		activeTab = 'search-preview';
		visitedTabs['search-preview'] = true;
		// eslint-disable-next-line svelte/no-navigation-without-resolve -- dynamically constructed welcome-consumed URL with query params; resolve() rejects non-typed route literals
		void goto(buildWelcomeConsumedSearchPreviewUrl(page.url));
	}

	const activateDocumentsTabFromSearchPreview = () => activateTab('documents');

	$effect(() => {
		showWelcomeBanner = currentUrlHasWelcomeBanner(page.url);
		const tabFromUrl = parseTabFromUrl(page.url);
		if (tabFromUrl && tabFromUrl !== activeTab) {
			activateTab(tabFromUrl);
		}
	});
</script>

<svelte:head>
	<title>{index.name} - Indexes - Flapjack Cloud</title>
</svelte:head>

<div onsubmit={trackSubmittedPostAction}>
	<nav class="mb-4 text-sm text-flapjack-ink/60">
		<a href={resolve('/console')} class="hover:text-flapjack-ink/80">Console</a>
		<span class="mx-1">/</span>
		<a href={resolve('/console/indexes')} class="hover:text-flapjack-ink/80">Indexes</a>
		<span class="mx-1">/</span>
		<span class="text-flapjack-ink">{index.name}</span>
	</nav>

	<div class="mb-6 flex items-center justify-between">
		<h1 class="text-2xl font-bold text-flapjack-ink">{index.name}</h1>
		<div class="flex items-center gap-2">
			<button
				type="button"
				onclick={() => {
					showSearchLog = !showSearchLog;
				}}
				class="rounded-md border border-flapjack-ink/30 px-3 py-1 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
			>
				Search Log
			</button>
			<span
				class="inline-flex rounded-full px-3 py-1 text-sm font-medium {indexStatusBadgeColor(
					index.status
				)}"
			>
				{statusLabel(index.status)}
			</span>
		</div>
	</div>

	{#if showWelcomeBanner}
		<div
			role="status"
			class="mb-4 flex flex-col gap-3 rounded-lg border border-flapjack-mint/60 bg-flapjack-mint/25 p-4 text-sm text-flapjack-ink sm:flex-row sm:items-center sm:justify-between"
		>
			<p class="font-medium">Index ready — try the search preview</p>
			<button
				type="button"
				class="rounded-md bg-flapjack-rose px-3 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
				onclick={activateSearchPreviewFromWelcomeBanner}
			>
				Open Search Preview
			</button>
		</div>
	{/if}

	<div class="relative mb-6">
		<div
			role="tablist"
			aria-label="Index detail sections"
			data-testid="index-tabs-strip"
			class="flex w-full flex-col gap-1 overflow-x-hidden rounded-lg border border-flapjack-ink/20 bg-white p-1 min-[600px]:flex-row min-[600px]:flex-nowrap min-[600px]:gap-0 min-[600px]:overflow-x-auto min-[600px]:overflow-y-hidden min-[600px]:snap-x min-[600px]:snap-mandatory min-[600px]:px-[2.75rem] min-[600px]:[scroll-padding-inline:2.75rem]"
		>
			{#each TAB_DEFINITIONS as tab (tab.id)}
				<button
					type="button"
					role="tab"
					aria-selected={activeTab === tab.id}
					data-testid={`tab-${tab.id}`}
					onclick={() => activateTab(tab.id)}
					class="w-full shrink-0 snap-start rounded-md px-4 py-2 text-left text-sm font-medium min-[600px]:w-auto min-[600px]:text-center {activeTab ===
					tab.id
						? 'bg-flapjack-rose text-white'
						: 'text-flapjack-ink/80 hover:bg-flapjack-cream/70'}"
				>
					{tab.label}
				</button>
			{/each}
		</div>
		<div
			aria-hidden="true"
			data-testid="index-tabs-fade-left"
			class="pointer-events-none absolute inset-y-1 left-1 hidden w-10 rounded-l-md bg-gradient-to-r from-flapjack-cream to-transparent min-[600px]:block"
		></div>
		<div
			aria-hidden="true"
			data-testid="index-tabs-fade-right"
			class="pointer-events-none absolute inset-y-1 right-1 hidden w-10 rounded-r-md bg-gradient-to-l from-flapjack-cream to-transparent min-[600px]:block"
		></div>
	</div>

	{#if visitedTabs.overview}
		<div hidden={activeTab !== 'overview'}>
			<OverviewTab
				{index}
				{replicas}
				{regions}
				{availableReplicaRegions}
				{searchResult}
				{searchQuery}
				{searchError}
				{replicaError}
				{deleteError}
				{replicaCreated}
			/>
		</div>
	{/if}

	{#if visitedTabs.settings}
		<div hidden={activeTab !== 'settings'}>
			<SettingsTab {settings} {settingsError} {settingsSaved} />
		</div>
	{/if}

	{#if visitedTabs.rules}
		<div hidden={activeTab !== 'rules'}>
			<RulesTab {rules} {ruleError} {ruleSaved} {ruleDeleted} {index} />
		</div>
	{/if}

	{#if visitedTabs.documents}
		<div hidden={activeTab !== 'documents'}>
			<DocumentsTab
				{index}
				{documents}
				{documentsUploadSuccess}
				{documentsAddSuccess}
				{documentsBrowseSuccess}
				{documentsDeleteSuccess}
				{documentsUploadError}
				{documentsAddError}
				{documentsBrowseError}
				{documentsDeleteError}
			/>
		</div>
	{/if}

	{#if visitedTabs.dictionaries}
		<div hidden={activeTab !== 'dictionaries'}>
			<DictionariesTab
				{index}
				{dictionaries}
				{dictionaryBrowseError}
				{dictionarySaveError}
				{dictionaryDeleteError}
				{dictionarySaved}
				{dictionaryDeleted}
			/>
		</div>
	{/if}

	{#if visitedTabs.synonyms}
		<div hidden={activeTab !== 'synonyms'}>
			<SynonymsTab {synonyms} {synonymError} {synonymSaved} {synonymDeleted} {index} />
		</div>
	{/if}

	{#if visitedTabs.personalization}
		<div hidden={activeTab !== 'personalization'}>
			<PersonalizationTab
				{index}
				{personalizationStrategy}
				{personalizationProfile}
				{personalizationError}
				{personalizationStrategySaved}
				{personalizationStrategyDeleted}
				{personalizationProfileDeleted}
			/>
		</div>
	{/if}

	{#if visitedTabs.recommendations}
		<div hidden={activeTab !== 'recommendations'}>
			<RecommendationsTab {index} {recommendationsResponse} {recommendationsError} />
		</div>
	{/if}

	{#if visitedTabs.chat}
		<div hidden={activeTab !== 'chat'}>
			<ChatTab {index} {chatResponse} {chatQuery} {chatError} />
		</div>
	{/if}

	{#if visitedTabs.suggestions}
		<div hidden={activeTab !== 'suggestions'}>
			<SuggestionsTab
				{qsConfig}
				{qsStatus}
				{qsConfigError}
				{qsConfigSaved}
				{qsConfigDeleted}
				{index}
			/>
		</div>
	{/if}

	{#if visitedTabs.analytics}
		<div hidden={activeTab !== 'analytics'}>
			<AnalyticsTab
				{searchCount}
				{noResultRate}
				{topSearches}
				{noResults}
				{analyticsStatus}
				{analyticsPeriod}
				startDate={analyticsStartDate}
				endDate={analyticsEndDate}
				{analyticsUnavailable}
			/>
		</div>
	{/if}

	{#if visitedTabs.merchandising}
		<div hidden={activeTab !== 'merchandising'}>
			<MerchandisingTab {index} {searchResult} {searchQuery} />
		</div>
	{/if}

	{#if visitedTabs.experiments}
		<div hidden={activeTab !== 'experiments'}>
			<ExperimentsTab {experiments} {experimentResultsMap} {experimentError} {index} />
		</div>
	{/if}

	{#if visitedTabs.events}
		<div hidden={activeTab !== 'events'}>
			<EventsTab {debugEvents} {eventsError} {eventsLoadError} {index} />
		</div>
	{/if}

	{#if visitedTabs['security-sources']}
		<div hidden={activeTab !== 'security-sources'}>
			<SecuritySourcesTab
				{index}
				{securitySources}
				{securitySourcesLoadError}
				{securitySourceAppendError}
				{securitySourceDeleteError}
				{securitySourceAppended}
				{securitySourceDeleted}
			/>
		</div>
	{/if}

	{#if visitedTabs['search-preview']}
		<div hidden={activeTab !== 'search-preview'}>
			<SearchPreviewTab
				{index}
				{previewKey}
				{previewKeyError}
				{previewIndexName}
				onRequestDocumentsTab={activateDocumentsTabFromSearchPreview}
			/>
		</div>
	{/if}

	<SearchLogPanel bind:visible={showSearchLog} />
</div>
