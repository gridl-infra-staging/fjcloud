<script lang="ts">
	import { browser } from '$app/environment';
	import { onDestroy } from 'svelte';
	import {
		buildSearchPreviewParams,
		createFlapjackInstantSearchClient
	} from '$lib/flapjack-search-client';
	import { buildSearchUrlWithState, parseSearchUrlState } from './search/search_url_state';
	import { loadSearchDisplayPrefs } from './search/display_prefs_storage';
	import { postSearchPreviewEvent } from './search/analytics_client';
	import SearchPreviewHeader from './search/SearchPreviewHeader.svelte';
	import SearchPreviewBox from './search/SearchPreviewBox.svelte';
	import SearchPreviewFacets from './search/SearchPreviewFacets.svelte';
	import SearchPreviewResults from './search/SearchPreviewResults.svelte';
	import HybridSearchControls from './search/HybridSearchControls.svelte';
	import DisplayPreferencesModal from './search/DisplayPreferencesModal.svelte';
	import type { FacetPanelModel } from './search/FacetPanel.svelte';

	type SearchHit = Record<string, unknown> & {
		objectID?: string;
	};

	type SearchResult = {
		hits?: SearchHit[];
		nbHits?: number;
		processingTimeMS?: number;
		page?: number;
		totalPages?: number;
		facetDistribution?: Record<string, Record<string, number>>;
		facetsDistribution?: Record<string, Record<string, number>>;
	};

	let {
		endpoint,
		apiKey,
		indexName,
		onRequestDocumentsTab = () => {},
		onPreviewKeyExpired = () => {}
	}: {
		endpoint: string;
		apiKey: string;
		indexName: string;
		onRequestDocumentsTab?: () => void;
		onPreviewKeyExpired?: () => void;
	} = $props();

	let query = $state('');
	let page = $state(1);
	let filters = $state<string[]>([]);
	let filterExpression = $state('');
	let filterExpressionVisible = $state(false);
	let hitsPerPage = $state(20);
	let highlightedAttributes = $state<string[]>([]);
	let showDisplayPreferences = $state(false);
	let trackAnalyticsEnabled = $state(false);
	let hybridEnabled = $state(false);
	let hits = $state<SearchHit[]>([]);
	let nbHits = $state(0);
	let processingTimeMS = $state(0);
	let totalPages = $state(1);
	let facetPanels = $state<FacetPanelModel[]>([]);
	let loading = $state(false);
	let searchError = $state('');
	let hydratedFromUrl = $state(false);
	let initialized = $state(false);

	const client = $derived(createFlapjackInstantSearchClient(endpoint, apiKey));

	let activeRequest = 0;

	function buildFacetPanels(
		distribution: Record<string, Record<string, number>>,
		selectedFilters: string[]
	): FacetPanelModel[] {
		const selected = new Set(selectedFilters);
		return Object.entries(distribution).map(([attribute, values]) => ({
			attribute,
			values: Object.entries(values)
				.map(([value, count]) => ({
					value,
					count,
					isRefined: selected.has(`${attribute}:${value}`)
				}))
				.sort((left, right) => right.count - left.count || left.value.localeCompare(right.value))
		}));
	}

	function syncUrlState(): void {
		if (!browser || !hydratedFromUrl) {
			return;
		}
		const nextUrl = buildSearchUrlWithState(window.location.href, {
			query,
			page,
			filters,
			hitsPerPage
		});
		window.history.replaceState(window.history.state, '', nextUrl);
	}

	function buildSearchParams(nextQuery: string): string {
		return buildSearchPreviewParams({
			query: nextQuery,
			facets: ['*'],
			facetFilters: filters.length > 0 ? filters.map((filter) => [filter]) : undefined,
			filters: filterExpression.trim() || undefined,
			// Flapjack search follows Algolia page numbering (zero-based), while
			// the UI and URL state remain one-based for users.
			page: Math.max(0, page - 1),
			hitsPerPage,
			attributesToHighlight: highlightedAttributes
		});
	}

	function statusFromError(error: unknown): number | null {
		if (!(error instanceof Error)) {
			return null;
		}
		const match = error.message.match(/Flapjack search failed: (\d{3})/);
		if (!match) {
			return null;
		}
		return Number.parseInt(match[1], 10);
	}

	async function runSearch(nextQuery: string): Promise<void> {
		if (!browser) return;

		searchError = '';
		loading = true;
		syncUrlState();

		const requestId = ++activeRequest;

		try {
			const response = await client.search([
				{
					indexName,
					params: buildSearchParams(nextQuery)
				}
			]);

			if (requestId !== activeRequest) {
				return;
			}

			const result = (response.results[0] ?? {}) as SearchResult;
			const nextHits = Array.isArray(result.hits) ? result.hits : [];
			const facetDistribution = result.facetDistribution ?? result.facetsDistribution ?? {};
			hits = nextHits;
			nbHits = typeof result.nbHits === 'number' ? result.nbHits : nextHits.length;
			processingTimeMS = typeof result.processingTimeMS === 'number' ? result.processingTimeMS : 0;
			page = typeof result.page === 'number' && result.page >= 0 ? result.page + 1 : page;
			totalPages =
				typeof result.totalPages === 'number' && result.totalPages > 0 ? result.totalPages : 1;
			facetPanels = buildFacetPanels(facetDistribution, filters);
		} catch (error) {
			if (requestId !== activeRequest) {
				return;
			}

			const status = statusFromError(error);
			if (status === 401 || status === 403) {
				onPreviewKeyExpired();
			}

			hits = [];
			nbHits = 0;
			processingTimeMS = 0;
			totalPages = 1;
			facetPanels = [];
			searchError = error instanceof Error ? error.message : 'Search failed';
		} finally {
			if (requestId === activeRequest) {
				loading = false;
			}
		}
	}

	function reloadDisplayPreferencesAndSearch(): void {
		const preferences = loadSearchDisplayPrefs();
		hitsPerPage = preferences.hitsPerPage;
		highlightedAttributes = preferences.highlightedAttributes;
		page = 1;
		void runSearch(query);
	}

	function handleQueryChange(nextQuery: string): void {
		query = nextQuery;
		page = 1;
		void runSearch(query);
	}

	function handleFilterExpressionVisibleChange(nextVisible: boolean): void {
		filterExpressionVisible = nextVisible;
	}

	function handleFilterExpressionChange(nextFilterExpression: string): void {
		filterExpression = nextFilterExpression;
		page = 1;
		void runSearch(query);
	}

	function handleToggleFacetValue(update: {
		attribute: string;
		value: string;
		nextRefined: boolean;
	}): void {
		const filterToken = `${update.attribute}:${update.value}`;
		if (update.nextRefined) {
			filters = filters.includes(filterToken) ? filters : [...filters, filterToken];
		} else {
			filters = filters.filter((existingFilter) => existingFilter !== filterToken);
		}
		page = 1;
		void runSearch(query);
	}

	function handleClearFacetAttribute(attribute: string): void {
		filters = filters.filter((existingFilter) => !existingFilter.startsWith(`${attribute}:`));
		page = 1;
		void runSearch(query);
	}

	function handleClearAllFacets(): void {
		filters = [];
		page = 1;
		void runSearch(query);
	}

	function handlePageChange(nextPage: number): void {
		page = Math.max(1, nextPage);
		void runSearch(query);
	}

	function handleTrackAnalyticsChange(nextEnabled: boolean): void {
		trackAnalyticsEnabled = nextEnabled;
	}

	function handleResultClick(hit: SearchHit, position: number): void {
		if (!trackAnalyticsEnabled) {
			return;
		}
		void postSearchPreviewEvent(endpoint, apiKey, {
			type: 'search_preview_result_click',
			query,
			indexName,
			metadata: {
				objectID: hit.objectID ?? null,
				page,
				position
			}
		}).catch(() => {
			// Analytics are fire-and-forget by design.
		});
	}

	$effect(() => {
		if (!browser || initialized) {
			return;
		}

		const currentUrl = new URL(window.location.href);
		const urlState = parseSearchUrlState(currentUrl.searchParams);
		const preferences = loadSearchDisplayPrefs();
		query = urlState.query;
		page = urlState.page;
		filters = urlState.filters;
		hitsPerPage = currentUrl.searchParams.has('hr')
			? urlState.hitsPerPage
			: preferences.hitsPerPage;
		highlightedAttributes = preferences.highlightedAttributes;
		filterExpressionVisible = filters.length > 0;
		hydratedFromUrl = true;
		initialized = true;

		if (query.length > 0) {
			void runSearch(query);
		}
	});

	onDestroy(() => {
		activeRequest += 1;
	});
</script>

<div data-testid="instantsearch-widget" class="space-y-4">
	<SearchPreviewHeader
		vectorState="unavailable"
		{trackAnalyticsEnabled}
		onTrackAnalyticsChange={handleTrackAnalyticsChange}
		onOpenDisplayPreferences={() => {
			showDisplayPreferences = true;
		}}
		onAddDocuments={onRequestDocumentsTab}
	/>

	<div data-testid="instantsearch-searchbox">
		<SearchPreviewBox
			{query}
			{filterExpression}
			{filterExpressionVisible}
			showFilterExpressionToggle={true}
			onQueryChange={handleQueryChange}
			onFilterExpressionVisibleChange={handleFilterExpressionVisibleChange}
			onFilterExpressionChange={handleFilterExpressionChange}
		/>
	</div>

	<HybridSearchControls
		capabilities={{ vectorSearch: false }}
		embedderCount={0}
		enabled={hybridEnabled}
		onHybridEnabledChange={(nextEnabled) => {
			hybridEnabled = nextEnabled;
		}}
	/>

	<SearchPreviewFacets
		panels={facetPanels}
		onToggleFacetValue={handleToggleFacetValue}
		onClearFacetAttribute={handleClearFacetAttribute}
		onClearAllFacets={handleClearAllFacets}
	/>

	{#if searchError}
		<p class="text-sm text-flapjack-plum">{searchError}</p>
	{/if}

	<div data-testid="instantsearch-hits">
		<SearchPreviewResults
			{nbHits}
			{processingTimeMS}
			{hits}
			{page}
			{totalPages}
			{loading}
			onPageChange={handlePageChange}
			onHitClick={handleResultClick}
		/>
	</div>

	<DisplayPreferencesModal
		open={showDisplayPreferences}
		onClose={() => {
			showDisplayPreferences = false;
			reloadDisplayPreferencesAndSearch();
		}}
	/>
</div>
