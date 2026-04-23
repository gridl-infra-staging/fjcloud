<script lang="ts">
	import { browser } from '$app/environment';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
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
	import {
		deriveFormLogEntry,
		extractFormAction
	} from '$lib/api-logs/dashboard-instrumentation';
	import { appendLogEntry } from '$lib/api-logs/store';

	let { data, form: formResult } = $props();

	const emptyExperiments: ExperimentListResponse = {
		abtests: [],
		count: 0,
		total: 0
	};

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
	const experiments: ExperimentListResponse = $derived(data.experiments ?? emptyExperiments);
	const experimentResultsMap: Record<string, ExperimentResults> = $derived(data.experimentResults ?? {});
	const documents: BrowseObjectsResponse = $derived(
		formResult?.documents ?? data.documents ?? emptyDocuments
	);
	const dictionaries = $derived(formResult?.dictionaries ?? data.dictionaries ?? emptyDictionaries);
	const securitySources: SecuritySourcesResponse = $derived(
		formResult?.securitySources ?? data.securitySources ?? { sources: [] }
	);
	const loadedDebugEvents: DebugEventsResponse | null = $derived(data.debugEvents ?? null);
	const refreshedDebugEvents: DebugEventsResponse | null = $derived(formResult?.refreshedEvents ?? null);
	const debugEvents: DebugEventsResponse | null = $derived(refreshedDebugEvents ?? loadedDebugEvents);

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

	let activeTab = $state<ActiveTab>('overview');
	let visitedTabs = $state<Record<ActiveTab, boolean>>(
		Object.fromEntries(TAB_DEFINITIONS.map((tab) => [tab.id, tab.id === 'overview'])) as Record<
			ActiveTab,
			boolean
		>
	);

	let showSearchLog = $state(false);
	let lastSubmittedAction = $state<string | null>(null);
	let lastLoggedFormResult: Record<string, unknown> | null = null;

	$effect(() => {
		if (formResult?.deleted && browser) {
			goto(resolve('/dashboard/indexes'));
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
	}
</script>

<svelte:head>
	<title>{index.name} - Indexes - Flapjack Cloud</title>
</svelte:head>

<div onsubmit={trackSubmittedPostAction}>
	<nav class="mb-4 text-sm text-gray-500">
		<a href={resolve('/dashboard')} class="hover:text-gray-700">Dashboard</a>
		<span class="mx-1">/</span>
		<a href={resolve('/dashboard/indexes')} class="hover:text-gray-700">Indexes</a>
		<span class="mx-1">/</span>
		<span class="text-gray-900">{index.name}</span>
	</nav>

	<div class="mb-6 flex items-center justify-between">
		<h1 class="text-2xl font-bold text-gray-900">{index.name}</h1>
		<div class="flex items-center gap-2">
			<button
				type="button"
				onclick={() => {
					showSearchLog = !showSearchLog;
				}}
				class="rounded-md border border-gray-300 px-3 py-1 text-sm font-medium text-gray-700 hover:bg-gray-100"
			>
				Search Log
			</button>
			<span class="inline-flex rounded-full px-3 py-1 text-sm font-medium {indexStatusBadgeColor(index.status)}">
				{statusLabel(index.status)}
			</span>
		</div>
	</div>

	<div role="tablist" aria-label="Index detail sections" class="mb-6 inline-flex rounded-lg border border-gray-200 bg-white p-1">
		{#each TAB_DEFINITIONS as tab (tab.id)}
			<button
				type="button"
				role="tab"
				aria-selected={activeTab === tab.id}
				data-testid={`tab-${tab.id}`}
				onclick={() => activateTab(tab.id)}
				class="rounded-md px-4 py-2 text-sm font-medium {activeTab === tab.id ? 'bg-blue-600 text-white' : 'text-gray-700 hover:bg-gray-100'}"
			>
				{tab.label}
			</button>
		{/each}
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
			<SuggestionsTab {qsConfig} {qsStatus} {qsConfigError} {qsConfigSaved} {qsConfigDeleted} {index} />
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
			<EventsTab {debugEvents} {eventsError} {index} />
		</div>
	{/if}

	{#if visitedTabs['security-sources']}
		<div hidden={activeTab !== 'security-sources'}>
			<SecuritySourcesTab
				{index}
				{securitySources}
				{securitySourceAppendError}
				{securitySourceDeleteError}
				{securitySourceAppended}
				{securitySourceDeleted}
			/>
		</div>
	{/if}

	{#if visitedTabs['search-preview']}
		<div hidden={activeTab !== 'search-preview'}>
			<SearchPreviewTab {index} {previewKey} {previewKeyError} {previewIndexName} />
		</div>
	{/if}

		<SearchLogPanel bind:visible={showSearchLog} />
	</div>
