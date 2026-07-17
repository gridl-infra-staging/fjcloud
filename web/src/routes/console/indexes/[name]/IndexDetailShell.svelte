<script lang="ts">
	import { browser } from '$app/environment';
	import { goto, pushState } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import type { ResolvedPathname } from '$app/types';
	import { onMount, untrack, type Component } from 'svelte';
	import { SvelteURLSearchParams } from 'svelte/reactivity';
	import { indexStatusBadgeColor, indexStatusLabel } from '$lib/format';
	import Tooltip from '$lib/components/Tooltip.svelte';
	import { normalizeExperimentList } from '$lib/experiment_helpers';
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
		IndexMetricsResponse,
		IndexChatResponse,
		IndexReplicaSummary,
		InternalRegion,
		PersonalizationProfile,
		PersonalizationStrategy,
		QsBuildStatus,
		QsConfig,
		RecommendationsBatchResponse,
		SearchResult,
		SecuritySourcesResponse,
		SynonymSearchResponse
	} from '$lib/api/types';
	import AnalyticsTab from './tabs/AnalyticsTab.svelte';
	import EventsTab from './tabs/EventsTab.svelte';
	import ExperimentsTab from './tabs/ExperimentsTab.svelte';
	import MerchandisingTab from './tabs/MerchandisingTab.svelte';
	import MetricsTab from './tabs/MetricsTab.svelte';
	import DocumentsTab from './tabs/DocumentsTab.svelte';
	import DictionariesTab from './tabs/DictionariesTab.svelte';
	import OverviewTab from './tabs/OverviewTab.svelte';
	import SettingsTab from './tabs/SettingsTab.svelte';
	import SuggestionsTab from './tabs/SuggestionsTab.svelte';
	import PersonalizationTab from './tabs/PersonalizationTab.svelte';
	import RecommendationsTab from './tabs/RecommendationsTab.svelte';
	import ChatTab from './tabs/ChatTab.svelte';
	import SearchTab from './tabs/SearchTab.svelte';
	import SecuritySourcesTab from './tabs/SecuritySourcesTab.svelte';
	import SynonymsTab from './tabs/SynonymsTab.svelte';
	import SearchLogPanel from './SearchLogPanel.svelte';
	import {
		ACTIVE_INDEX_DETAIL_TAB_IDS,
		INDEX_DETAIL_TABS,
		type IndexDetailTabId
	} from './index_detail_tabs';
	import type { RuleListPayload } from './tabs/rule_payload';
	import { formResultOwnerTab } from './index_detail_form_result_tabs';
	import { deriveFormLogEntry, extractFormAction } from '$lib/api-logs/dashboard-instrumentation';
	import { appendLogEntry } from '$lib/api-logs/store';

	type DictionariesPayload = {
		languages: DictionaryLanguagesResponse | null;
		selectedDictionary: DictionaryName;
		selectedLanguage: string;
		entries: DictionarySearchResponse;
	};

	type IndexDetailShellData = Record<string, unknown> & {
		index: Index;
		rawIndexName?: string;
		settings?: Record<string, unknown> | null;
		replicas?: IndexReplicaSummary[];
		regions?: InternalRegion[];
		rules?: RuleListPayload | null;
		synonyms?: SynonymSearchResponse | null;
		personalizationStrategy?: PersonalizationStrategy | null;
		qsConfig?: QsConfig | null;
		qsStatus?: QsBuildStatus | null;
		searchCount?: AnalyticsSearchCountResponse | null;
		noResultRate?: AnalyticsNoResultRateResponse | null;
		topSearches?: AnalyticsTopSearchesResponse | null;
		noResults?: AnalyticsTopSearchesResponse | null;
		analyticsStatus?: AnalyticsStatusResponse | null;
		analyticsPeriod?: '7d' | '30d' | '90d';
		analyticsStartDate?: string;
		analyticsEndDate?: string;
		experiments?: ExperimentListResponse | null;
		allIndexes?: Index[];
		experimentResults?: Record<string, ExperimentResults>;
		documents?: BrowseObjectsResponse;
		dictionaries?: DictionariesPayload;
		securitySources?: SecuritySourcesResponse;
		securitySourcesLoadError?: string;
		debugEvents?: DebugEventsResponse | null;
		eventsLoadError?: string;
		metrics?: IndexMetricsResponse | null;
		metricsError?: { code: number; message: string } | null;
	};

	type IndexDetailShellFormData = Record<string, unknown> & {
		deleted?: boolean;
		searchResult?: SearchResult | null;
		query?: string;
		searchError?: string;
		replicaError?: string;
		replicaCreated?: boolean;
		restoreError?: string;
		restoreStarted?: boolean;
		deleteError?: string;
		settingsError?: string;
		settingsSaved?: boolean;
		ruleError?: string;
		ruleSaved?: boolean;
		ruleDeleted?: boolean;
		rulesCleared?: boolean;
		rulesClearError?: string;
		synonymError?: string;
		synonymSaved?: boolean;
		synonymDeleted?: boolean;
		synonymsCleared?: boolean;
		personalizationError?: string;
		personalizationStrategySaved?: boolean;
		personalizationStrategyDeleted?: boolean;
		personalizationProfile?: PersonalizationProfile | null;
		personalizationProfileDeleted?: boolean;
		personalizationProfileLookupAttempted?: boolean;
		recommendationsResponse?: RecommendationsBatchResponse | null;
		recommendationsError?: string;
		chatResponse?: IndexChatResponse | null;
		chatQuery?: string;
		chatError?: string;
		qsConfigError?: string;
		qsConfigSaved?: boolean;
		qsConfigDeleted?: boolean;
		qsBuildQueued?: boolean;
		experimentError?: string;
		eventsError?: string;
		documents?: BrowseObjectsResponse;
		documentsUploadError?: string;
		documentsUploadSuccess?: boolean;
		documentsAddError?: string;
		documentsAddSuccess?: boolean;
		documentsBrowseError?: string;
		documentsBrowseSuccess?: boolean;
		documentsDeleteError?: string;
		documentsDeleteSuccess?: boolean;
		dictionaries?: DictionariesPayload;
		dictionaryBrowseError?: string;
		dictionarySaveError?: string;
		dictionarySaved?: boolean;
		dictionaryDeleteError?: string;
		dictionaryDeleted?: boolean;
		dictionaryClearError?: string;
		dictionaryCleared?: boolean;
		securitySources?: SecuritySourcesResponse;
		securitySourcesReloaded?: boolean;
		securitySourcesLoadError?: string;
		securitySourceAppendError?: string;
		securitySourceAppended?: boolean;
		securitySourceDeleteError?: string;
		securitySourceDeleted?: boolean;
		refreshedEvents?: DebugEventsResponse | null;
	};

	let {
		data,
		form: formResult = null,
		initialTabOverride = null,
		ExperimentsTabComponent = null,
		experimentsTabProps = {}
	}: {
		data: IndexDetailShellData;
		form?: IndexDetailShellFormData | null;
		initialTabOverride?: string | null;
		ExperimentsTabComponent?: Component<Record<string, unknown>> | null;
		experimentsTabProps?: Record<string, unknown>;
	} = $props();

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

	const emptyDictionaries: DictionariesPayload = {
		languages: null,
		selectedDictionary: 'stopwords',
		selectedLanguage: '',
		entries: emptyDictionaryEntries
	};

	const index: Index = $derived(data.index);
	const rawIndexName: string = $derived(data.rawIndexName ?? index.name);
	const settings: Record<string, unknown> | null = $derived(data.settings ?? null);
	const replicas: IndexReplicaSummary[] = $derived(data.replicas ?? []);
	const regions: InternalRegion[] = $derived(data.regions ?? []);
	const rules: RuleListPayload | null = $derived(data.rules ?? null);
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
	const experiments: ExperimentListResponse = $derived(normalizeExperimentList(data.experiments));
	const allIndexes: Index[] = $derived((data.allIndexes as Index[]) ?? []);
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
	const metrics: IndexMetricsResponse | null = $derived(data.metrics ?? null);
	const metricsError: { code: number; message: string } | null = $derived(
		data.metricsError ?? null
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

	const personalizationProfile: PersonalizationProfile | null = $derived(
		formResult?.personalizationProfile ?? null
	);
	const recommendationsResponse: RecommendationsBatchResponse | null = $derived(
		formResult?.recommendationsResponse ?? null
	);
	const chatResponse: IndexChatResponse | null = $derived(formResult?.chatResponse ?? null);
	const chatQuery: string = $derived(formResult?.chatQuery ?? '');

	const replicaError: string = $derived(formResult?.replicaError ?? '');
	const restoreError: string = $derived(formResult?.restoreError ?? '');
	const deleteError: string = $derived(formResult?.deleteError ?? '');
	const settingsError: string = $derived(formResult?.settingsError ?? '');
	const ruleError: string = $derived(formResult?.ruleError ?? '');
	const rulesClearError: string = $derived(formResult?.rulesClearError ?? '');
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
	const dictionaryClearError: string = $derived(formResult?.dictionaryClearError ?? '');
	const securitySourceAppendError: string = $derived(formResult?.securitySourceAppendError ?? '');
	const securitySourceDeleteError: string = $derived(formResult?.securitySourceDeleteError ?? '');
	const replicaCreated: boolean = $derived(Boolean(formResult?.replicaCreated));
	const settingsSaved: boolean = $derived(Boolean(formResult?.settingsSaved));
	const ruleSaved: boolean = $derived(Boolean(formResult?.ruleSaved));
	const ruleDeleted: boolean = $derived(Boolean(formResult?.ruleDeleted));
	const rulesCleared: boolean = $derived(Boolean(formResult?.rulesCleared));
	const synonymSaved: boolean = $derived(Boolean(formResult?.synonymSaved));
	const synonymDeleted: boolean = $derived(Boolean(formResult?.synonymDeleted));
	const synonymsCleared: boolean = $derived(Boolean(formResult?.synonymsCleared));
	const personalizationStrategySaved: boolean = $derived(
		Boolean(formResult?.personalizationStrategySaved)
	);
	const personalizationStrategyDeleted: boolean = $derived(
		Boolean(formResult?.personalizationStrategyDeleted)
	);
	const personalizationProfileDeleted: boolean = $derived(
		Boolean(formResult?.personalizationProfileDeleted)
	);
	const personalizationProfileLookupAttemptedFromForm: boolean = $derived(
		formResult?.personalizationProfileLookupAttempted === true
	);
	const qsConfigSaved: boolean = $derived(Boolean(formResult?.qsConfigSaved));
	const qsConfigDeleted: boolean = $derived(Boolean(formResult?.qsConfigDeleted));
	const qsBuildQueued: boolean = $derived(Boolean(formResult?.qsBuildQueued));
	const documentsUploadSuccess: boolean = $derived(Boolean(formResult?.documentsUploadSuccess));
	const documentsAddSuccess: boolean = $derived(Boolean(formResult?.documentsAddSuccess));
	const documentsBrowseSuccess: boolean = $derived(Boolean(formResult?.documentsBrowseSuccess));
	const dictionarySaved: boolean = $derived(Boolean(formResult?.dictionarySaved));
	const dictionaryDeleted: boolean = $derived(Boolean(formResult?.dictionaryDeleted));
	const dictionaryCleared: boolean = $derived(Boolean(formResult?.dictionaryCleared));

	let dictionaryActionVersion = $state(0);
	$effect(() => {
		void formResult;
		untrack(() => {
			dictionaryActionVersion += 1;
		});
	});
	const securitySourceAppended: boolean = $derived(Boolean(formResult?.securitySourceAppended));
	const securitySourceDeleted: boolean = $derived(Boolean(formResult?.securitySourceDeleted));

	type ActiveTab = IndexDetailTabId;

	function normalizeTabId(rawTab: string | null): ActiveTab | null {
		if (!rawTab) return null;
		if (rawTab === 'rules') return 'merchandising';
		if (!ACTIVE_INDEX_DETAIL_TAB_IDS.has(rawTab as ActiveTab)) return null;
		return rawTab as ActiveTab;
	}

	function parseTabFromUrl(currentUrl: URL): ActiveTab | null {
		return normalizeTabId(currentUrl.searchParams.get('tab'));
	}

	function buildTabHref(currentUrl: URL, tab: ActiveTab): ResolvedPathname {
		const nextSearchParams = new SvelteURLSearchParams(currentUrl.searchParams);
		nextSearchParams.set('tab', tab);
		const indexPath = resolve('/console/indexes/[name]', { name: index.name });
		return `${indexPath}?${nextSearchParams.toString()}` as ResolvedPathname;
	}

	function currentNavigationUrl(): URL {
		return browser ? new URL(window.location.href) : page.url;
	}

	function inferInitialTab(currentUrl: URL): ActiveTab {
		const tabOverride = normalizeTabId(initialTabOverride);
		if (tabOverride) {
			return tabOverride;
		}
		return /\/experiments\/[^/]+$/.test(currentUrl.pathname) ? 'experiments' : 'overview';
	}

	function tabForUrl(currentUrl: URL): ActiveTab {
		return parseTabFromUrl(currentUrl) ?? inferInitialTab(currentUrl);
	}

	const initialTab = parseTabFromUrl(page.url) ?? inferInitialTab(page.url);
	let activeTab = $state<ActiveTab>(initialTab);
	let visitedTabs = $state<Record<ActiveTab, boolean>>(
		Object.fromEntries(INDEX_DETAIL_TABS.map((tab) => [tab.id, tab.id === initialTab])) as Record<
			ActiveTab,
			boolean
		>
	);
	let showSearchLog = $state(false);
	let lastSubmittedAction = $state<string | null>(null);
	let lastLoggedFormResult: Record<string, unknown> | null = null;
	let personalizationProfileLookupInFlight = $state(false);
	let personalizationProfileLookupAttemptedLocal = $state(false);
	let lastHandledProfileStateFormResult: Record<string, unknown> | null = null;
	let interactiveReady = $state(false);
	const personalizationProfileLookupAttempted: boolean = $derived(
		personalizationProfileLookupAttemptedFromForm || personalizationProfileLookupAttemptedLocal
	);

	onMount(() => {
		interactiveReady = true;
	});

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

	$effect(() => {
		const ownerTab = formResultOwnerTab(formResult);
		if (!ownerTab) return;
		activeTab = ownerTab;
		visitedTabs[ownerTab] = true;
	});

	$effect(() => {
		if ((formResult ?? null) === lastHandledProfileStateFormResult) return;
		lastHandledProfileStateFormResult = formResult ?? null;
		personalizationProfileLookupInFlight = false;
		if (formResult?.personalizationProfileDeleted === true) {
			personalizationProfileLookupAttemptedLocal = false;
			return;
		}
		if (
			lastSubmittedAction === '?/getPersonalizationProfile' ||
			formResult?.personalizationProfileLookupAttempted === true
		) {
			personalizationProfileLookupAttemptedLocal = true;
		}
	});

	function trackSubmittedPostAction(event: SubmitEvent) {
		lastSubmittedAction = extractFormAction(event);
		if (lastSubmittedAction === '?/getPersonalizationProfile') {
			personalizationProfileLookupInFlight = true;
		}
	}

	function activateTab(tab: ActiveTab) {
		if (browser) {
			const currentUrl = currentNavigationUrl();
			const currentUrlTab = parseTabFromUrl(currentUrl);
			if (currentUrlTab === tab) {
				activeTab = tab;
				visitedTabs[tab] = true;
				return;
			}

			// eslint-disable-next-line svelte/no-navigation-without-resolve -- buildTabHref resolves the typed base route, then appends dynamic tab query params that resolve() rejects.
			pushState(buildTabHref(currentUrl, tab), {});
		}

		activeTab = tab;
		visitedTabs[tab] = true;
	}

	function activateDocumentsTabFromSearch() {
		activateTab('documents');
	}

	const overviewAnalyticsTabHref = $derived(buildTabHref(page.url, 'analytics'));

	$effect(() => {
		const currentUrl = page.url;
		const tabFromUrl = tabForUrl(currentUrl);
		const currentActiveTab = untrack(() => activeTab);
		if (tabFromUrl !== currentActiveTab) {
			if (browser && parseTabFromUrl(currentNavigationUrl()) === currentActiveTab) {
				return;
			}
			activeTab = tabFromUrl;
			visitedTabs[tabFromUrl] = true;
		}
	});

	function indexStatusExplanation(status: string): string {
		switch (status) {
			case 'ready':
			case 'healthy':
				return 'Available means this index is reachable and ready to serve searches.';
			case 'unknown':
				return 'Checking status means a live availability check has not completed yet.';
			case 'provisioning':
				return 'Preparing means the index is still being created and cannot serve searches yet.';
			case 'unhealthy':
				return 'Unavailable means the index did not pass its latest availability check.';
			default:
				return `Current index status: ${indexStatusLabel(status)}.`;
		}
	}
</script>

<svelte:head>
	<title>{index.name} - Indexes - Flapjack Cloud</title>
</svelte:head>

<div onsubmit={trackSubmittedPostAction}>
	<nav class="mb-4 text-sm text-flapjack-ink/60" aria-label="Breadcrumb">
		<a href={resolve('/console')} class="hover:text-flapjack-ink/80">Console</a>
		<span class="mx-1">/</span>
		<a href={resolve('/console/indexes')} class="hover:text-flapjack-ink/80">Indexes</a>
		<span class="mx-1">/</span>
		{#if activeTab === 'settings'}
			<a
				href={resolve('/console/indexes/[name]', { name: index.name })}
				class="hover:text-flapjack-ink/80">{index.name}</a
			>
			<span class="mx-1">/</span>
			<span class="text-flapjack-ink">Settings</span>
		{:else}
			<span class="text-flapjack-ink">{index.name}</span>
		{/if}
	</nav>

	<div class="mb-6 flex items-center justify-between">
		<h1 class="text-2xl font-bold text-flapjack-ink">{index.name}</h1>
		<div class="flex items-center gap-2">
			<button
				type="button"
				disabled={!interactiveReady}
				onclick={() => {
					showSearchLog = !showSearchLog;
				}}
				class="rounded-md border border-flapjack-ink/30 px-3 py-1 text-sm font-medium text-flapjack-ink/80 transition-colors hover:border-flapjack-rose hover:bg-flapjack-cream/70 hover:text-flapjack-plum disabled:cursor-not-allowed disabled:opacity-60"
				aria-expanded={showSearchLog}
				aria-controls="index-api-activity-log"
			>
				API Activity Log
			</button>
			<span
				class="inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-sm font-medium {indexStatusBadgeColor(
					index.status
				)}"
			>
				<span aria-hidden="true">{index.status === 'ready' || index.status === 'healthy' ? '●' : '◌'}</span>
				{indexStatusLabel(index.status)}
			</span>
			<Tooltip
				triggerLabel="About index availability"
				message={indexStatusExplanation(index.status)}
				idBase="index-availability"
			/>
		</div>
	</div>

	<div id="index-api-activity-log">
		<SearchLogPanel bind:visible={showSearchLog} />
	</div>

	<div class="relative mb-6">
		<div
			role="tablist"
			aria-label="Index detail sections"
			data-testid="index-tabs-strip"
			class="flex w-full flex-col gap-1 overflow-x-hidden rounded-lg border border-flapjack-ink/20 bg-white p-1 min-[600px]:flex-row min-[600px]:flex-nowrap min-[600px]:gap-0 min-[600px]:overflow-x-auto min-[600px]:overflow-y-hidden min-[600px]:snap-x min-[600px]:snap-mandatory min-[600px]:px-[2.75rem] min-[600px]:[scroll-padding-inline:2.75rem]"
		>
			{#each INDEX_DETAIL_TABS as tab (tab.id)}
				<button
					type="button"
					role="tab"
					aria-selected={activeTab === tab.id}
					data-testid={`tab-${tab.id}`}
					disabled={!interactiveReady}
					onclick={() => activateTab(tab.id)}
					class="w-full shrink-0 snap-start rounded-md px-4 py-2 text-left text-sm font-medium min-[600px]:w-auto min-[600px]:text-center {activeTab ===
					tab.id
						? 'bg-flapjack-rose text-white'
						: 'text-flapjack-ink/80 hover:bg-flapjack-cream/70'} disabled:cursor-not-allowed disabled:opacity-60"
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
				{replicaError}
				{deleteError}
				{replicaCreated}
				{documentsUploadError}
				analyticsTabHref={overviewAnalyticsTabHref}
			/>
		</div>
	{/if}

	{#if visitedTabs.settings}
		<div data-testid="settings-section" hidden={activeTab !== 'settings'}>
			<SettingsTab {settings} {settingsError} {settingsSaved} />
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
				{dictionaryActionVersion}
				{dictionaryBrowseError}
				{dictionarySaveError}
				{dictionaryDeleteError}
				{dictionaryClearError}
				{dictionarySaved}
				{dictionaryDeleted}
				{dictionaryCleared}
			/>
		</div>
	{/if}

	{#if visitedTabs.synonyms}
		<div hidden={activeTab !== 'synonyms'}>
			<SynonymsTab
				{synonyms}
				{synonymError}
				{synonymSaved}
				{synonymDeleted}
				{synonymsCleared}
				{index}
			/>
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
				{personalizationProfileLookupInFlight}
				{personalizationProfileLookupAttempted}
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
				{qsBuildQueued}
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

	{#if visitedTabs.metrics}
		<div hidden={activeTab !== 'metrics'}>
			<MetricsTab {metrics} error={metricsError} indexName={index.name} />
		</div>
	{/if}

	{#if visitedTabs.merchandising}
		<div hidden={activeTab !== 'merchandising'}>
			<MerchandisingTab
				{index}
				{rules}
				{ruleError}
				{ruleSaved}
				{ruleDeleted}
				{rulesCleared}
				{rulesClearError}
			/>
		</div>
	{/if}

	{#if visitedTabs.experiments}
		<div hidden={activeTab !== 'experiments'}>
			{#if ExperimentsTabComponent}
				<ExperimentsTabComponent {...experimentsTabProps} {experimentError} />
			{:else}
				<ExperimentsTab
					{experiments}
					{experimentResultsMap}
					{experimentError}
					{index}
					{allIndexes}
				/>
			{/if}
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

	{#if visitedTabs.search}
		<div hidden={activeTab !== 'search'}>
			<SearchTab
				{index}
				{rawIndexName}
				{restoreError}
				{settings}
				{documents}
				{rules}
				onRequestDocumentsTab={activateDocumentsTabFromSearch}
			/>
		</div>
	{/if}

</div>
