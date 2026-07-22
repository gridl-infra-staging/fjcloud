<script lang="ts">
	import { browser } from '$app/environment';
	import { onDestroy, tick } from 'svelte';
	import { cycleFocusWithin } from '$lib/utils/focus_trap';
	import {
		buildSearchPreviewParams,
		createDashboardInstantSearchClient,
		type NormalizedInstantSearchResult
	} from '$lib/flapjack-search-client';
	import { buildSearchUrlWithState, parseSearchUrlState } from './search/search_url_state';
	import {
		loadInstantSearchEnabled,
		saveInstantSearchEnabled
	} from './search/instant_search_storage';
	import { getSearchPreviewSessionToken, postSearchPreviewEvent } from './search/analytics_client';
	import SearchPreviewHeader from './search/SearchPreviewHeader.svelte';
	import SearchPreviewBox from './search/SearchPreviewBox.svelte';
	import SearchPreviewFacets from './search/SearchPreviewFacets.svelte';
	import SearchPreviewResults from './search/SearchPreviewResults.svelte';
	import HybridSearchControls from './search/HybridSearchControls.svelte';
	import type { FacetPanelModel } from './search/FacetPanel.svelte';

	type SearchHit = Record<string, unknown> & {
		objectID?: string;
	};

	type SearchResult = NormalizedInstantSearchResult & {
		hits?: SearchHit[];
		nbHits?: number;
		processingTimeMS?: number;
		page?: number;
		totalPages?: number;
		nbPages?: number;
		hitsPerPage?: number;
	};

	let {
		indexName,
		configuredFacets = null,
		documentSample = [],
		onRequestDocumentsTab = () => {},
		pinnedPositions = new Map()
	}: {
		indexName: string;
		configuredFacets?: string[] | null;
		documentSample?: SearchHit[];
		onRequestDocumentsTab?: () => void;
		pinnedPositions?: Map<string, number>;
	} = $props();

	let query = $state('');
	let page = $state(1);
	let filters = $state<string[]>([]);
	let filterExpression = $state('');
	let filterExpressionVisible = $state(false);
	let hitsPerPage = $state(20);
	let highlightedAttributes = $state<string[]>([]);
	let instantSearchEnabled = $state(false);
	let titleField = $state<string | null>(null);
	let subtitleField = $state<string | null>(null);
	let imageField = $state<string | null>(null);
	let tagsField = $state<string | null>(null);
	let showJsonView = $state(false);
	let trackAnalyticsEnabled = $state(false);
	let analyticsQueryID = $state<string | null>(null);
	let analyticsSearchRequired = $state(false);
	let analyticsStatusMessage = $state('');
	let merchModeEnabled = $state(false);
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
	let querySyncVersion = $state(0);
	let mobileRefineOpen = $state(false);
	let mobileRefineTrigger = $state<HTMLButtonElement | null>(null);
	let mobileRefineDialog = $state<HTMLDialogElement | null>(null);

	const client = $derived(createDashboardInstantSearchClient(indexName));

	function availableAttributesFor(searchHits: SearchHit[]): string[] {
		const seen: string[] = [];
		for (const hit of [...documentSample, ...searchHits]) {
			for (const key of Object.keys(hit)) {
				if (key === '_highlightResult') continue;
				if (!seen.includes(key)) {
					seen.push(key);
				}
			}
		}
		return seen.sort((left, right) => left.localeCompare(right));
	}

	let activeRequest = 0;

	function buildFacetPanels(
		distribution: Record<string, Record<string, number>>,
		selectedFilters: string[],
		attributes: string[]
	): FacetPanelModel[] {
		const selected = new Set(selectedFilters);
		return attributes.map((attribute) => ({
			attribute,
			values: Object.entries(distribution[attribute] ?? {})
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
			attributesToHighlight: highlightedAttributes,
			analytics: trackAnalyticsEnabled,
			clickAnalytics: trackAnalyticsEnabled ? true : undefined
		});
	}

	function positiveIntegerOrNull(value: unknown): number | null {
		return typeof value === 'number' && Number.isFinite(value) && value > 0
			? Math.floor(value)
			: null;
	}

	function normalizeTotalPages(result: SearchResult): number {
		return positiveIntegerOrNull(result.totalPages) ?? positiveIntegerOrNull(result.nbPages) ?? 1;
	}

	async function runSearch(nextQuery: string): Promise<void> {
		if (!browser) return;

		searchError = '';
		loading = true;
		// Retained hits belong to the previous response while replacement search is
		// in flight. Clear correlation now so an old hit cannot be paired with the
		// new query text and an old query ID.
		analyticsQueryID = null;
		analyticsSearchRequired = false;
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
			const responseTotalPages = normalizeTotalPages(result);
			hits = nextHits;
			applyDeterministicDisplayDefaults(nextHits);
			nbHits = typeof result.nbHits === 'number' ? result.nbHits : nextHits.length;
			processingTimeMS = typeof result.processingTimeMS === 'number' ? result.processingTimeMS : 0;
			totalPages = responseTotalPages;
			page =
				typeof result.page === 'number' && result.page >= 0
					? Math.min(result.page + 1, responseTotalPages)
					: Math.min(page, responseTotalPages);
			facetPanels = buildFacetPanels(result.facets, filters, configuredFacets ?? []);
			analyticsQueryID = typeof result.queryID === 'string' ? result.queryID : null;
			syncUrlState();
		} catch (error) {
			if (requestId !== activeRequest) {
				return;
			}

			analyticsQueryID = null;
			searchError = error instanceof Error ? error.message : 'Search failed';
		} finally {
			if (requestId === activeRequest) {
				loading = false;
			}
		}
	}

	function firstAvailableAttribute(candidates: string[], attributes: string[]): string | null {
		return candidates.find((candidate) => attributes.includes(candidate)) ?? null;
	}

	function applyDeterministicDisplayDefaults(searchHits: SearchHit[] = hits): void {
		const attributes = availableAttributesFor(searchHits);
		titleField = firstAvailableAttribute(['title', 'name', 'objectID'], attributes);
		subtitleField = firstAvailableAttribute(['overview', 'description'], attributes);
		imageField = firstAvailableAttribute(['poster_url', 'image_url', 'image'], attributes);
		tagsField = firstAvailableAttribute(
			['genre', 'genres', 'category', 'categories', 'tags'],
			attributes
		);
	}

	function handleQueryChange(nextQuery: string): void {
		query = nextQuery;
		page = 1;
		void runSearch(query);
	}

	function handleInstantSearchEnabledChange(nextEnabled: boolean): void {
		instantSearchEnabled = nextEnabled;
		saveInstantSearchEnabled(indexName, nextEnabled);
	}

	function handleFilterExpressionVisibleChange(nextVisible: boolean): void {
		filterExpressionVisible = nextVisible;
	}

	function handleFilterExpressionChange(nextFilterExpression: string): void {
		filterExpression = nextFilterExpression;
		page = 1;
		resyncVisibleQueryInputToCommittedQuery();
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
		resyncVisibleQueryInputToCommittedQuery();
		void runSearch(query);
	}

	function handleClearFacetAttribute(attribute: string): void {
		filters = filters.filter((existingFilter) => !existingFilter.startsWith(`${attribute}:`));
		page = 1;
		resyncVisibleQueryInputToCommittedQuery();
		void runSearch(query);
	}

	function handleClearAllFacets(): void {
		filters = [];
		page = 1;
		resyncVisibleQueryInputToCommittedQuery();
		void runSearch(query);
	}

	function handleClearAllFilters(): void {
		filters = [];
		filterExpression = '';
		page = 1;
		resyncVisibleQueryInputToCommittedQuery();
		void runSearch(query);
	}

	function handlePageChange(nextPage: number): void {
		const boundedPage = Math.min(Math.max(1, nextPage), Math.max(1, totalPages));
		if (boundedPage === page) {
			return;
		}
		page = boundedPage;
		resyncVisibleQueryInputToCommittedQuery();
		void runSearch(query);
	}

	function handleHitsPerPageChange(nextHitsPerPage: number): void {
		if (
			!Number.isFinite(nextHitsPerPage) ||
			nextHitsPerPage <= 0 ||
			nextHitsPerPage === hitsPerPage
		) {
			return;
		}
		hitsPerPage = Math.floor(nextHitsPerPage);
		page = 1;
		resyncVisibleQueryInputToCommittedQuery();
		void runSearch(query);
	}

	async function openMobileRefine(trigger: HTMLButtonElement): Promise<void> {
		mobileRefineTrigger = trigger;
		mobileRefineOpen = true;
		await tick();
		document.querySelector<HTMLButtonElement>('[data-testid="refine-drawer-close"]')?.focus();
	}

	async function closeMobileRefine(): Promise<void> {
		mobileRefineOpen = false;
		await tick();
		mobileRefineTrigger?.focus();
	}

	function handleMobileRefineKeydown(event: KeyboardEvent): void {
		if (event.key === 'Escape') {
			event.preventDefault();
			void closeMobileRefine();
			return;
		}
		if (mobileRefineDialog) cycleFocusWithin(event, mobileRefineDialog);
	}

	function resyncVisibleQueryInputToCommittedQuery(): void {
		querySyncVersion += 1;
	}

	function handleTrackAnalyticsChange(nextEnabled: boolean): void {
		trackAnalyticsEnabled = nextEnabled;
		// A query ID is only valid for the analytics flags used by the search that
		// produced it. Changing the opt-in state invalidates any prior correlation.
		analyticsQueryID = null;
		analyticsSearchRequired = nextEnabled;
		analyticsStatusMessage = nextEnabled
			? 'Preview activity recording is on. Run a new search to record result opens.'
			: '';
	}

	function handleMerchModeChange(nextEnabled: boolean): void {
		merchModeEnabled = nextEnabled;
	}

	function handleResultClick(hit: SearchHit, position: number): void {
		if (!trackAnalyticsEnabled) {
			return;
		}
		if (loading) {
			analyticsStatusMessage = 'Not recorded: wait for the current search to finish.';
			return;
		}
		if (analyticsSearchRequired) {
			analyticsStatusMessage = 'Not recorded: run a new search after enabling preview activity.';
			return;
		}
		if (!analyticsQueryID) {
			analyticsStatusMessage = 'Not recorded: the search response did not include a query ID.';
			return;
		}
		if (typeof hit.objectID !== 'string' || hit.objectID.length === 0) {
			analyticsStatusMessage = 'Not recorded: the result does not include an object ID.';
			return;
		}
		const absolutePosition = (page - 1) * hitsPerPage + position;
		void postSearchPreviewEvent(indexName, {
			eventName: 'search_preview_result_opened',
			objectID: hit.objectID,
			position: absolutePosition,
			queryID: analyticsQueryID,
			userToken: getSearchPreviewSessionToken()
		})
			.then(() => {
				analyticsStatusMessage = 'Recorded result open.';
			})
			.catch((error: unknown) => {
				analyticsStatusMessage = `Result open was not recorded: ${
					error instanceof Error ? error.message : 'unknown error'
				}`;
			});
	}

	$effect(() => {
		if (!browser || initialized) {
			return;
		}

		const currentUrl = new URL(window.location.href);
		const urlState = parseSearchUrlState(currentUrl.searchParams);
		instantSearchEnabled = loadInstantSearchEnabled(indexName);
		applyDeterministicDisplayDefaults();
		facetPanels = buildFacetPanels({}, filters, configuredFacets ?? []);
		query = urlState.query;
		page = urlState.page;
		filters = urlState.filters;
		if (currentUrl.searchParams.has('hr')) {
			hitsPerPage = urlState.hitsPerPage;
		}
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
		{analyticsStatusMessage}
		onTrackAnalyticsChange={handleTrackAnalyticsChange}
		{merchModeEnabled}
		onMerchModeChange={handleMerchModeChange}
		onAddDocuments={onRequestDocumentsTab}
	/>

	<div
		class="rounded-lg border border-flapjack-ink/15 bg-white p-4"
		data-testid="search-query-toolbar"
	>
		<div data-testid="instantsearch-searchbox">
			<SearchPreviewBox
				{query}
				{querySyncVersion}
				{instantSearchEnabled}
				onInstantSearchEnabledChange={handleInstantSearchEnabledChange}
				{filterExpression}
				{filterExpressionVisible}
				showFilterExpressionToggle={true}
				onQueryChange={handleQueryChange}
				onFilterExpressionVisibleChange={handleFilterExpressionVisibleChange}
				onFilterExpressionChange={handleFilterExpressionChange}
			/>
		</div>
		{#if filters.length > 0}
			<div class="mt-3 flex flex-wrap gap-2" aria-label="Active refinements">
				{#each filters as filter (filter)}
					<button
						type="button"
						class="rounded-full bg-flapjack-cream px-3 py-1 text-xs text-flapjack-ink hover:bg-flapjack-rose/15"
						onclick={() => {
							filters = filters.filter((candidate) => candidate !== filter);
							page = 1;
							void runSearch(query);
						}}
					>
						{filter} <span aria-hidden="true">×</span>
					</button>
				{/each}
			</div>
		{/if}
	</div>

	<HybridSearchControls
		capabilities={{ vectorSearch: false }}
		embedderCount={0}
		enabled={hybridEnabled}
		onHybridEnabledChange={(nextEnabled) => {
			hybridEnabled = nextEnabled;
		}}
	/>

	{#if searchError}
		<div class="flex items-center gap-3" role="alert">
			<p class="text-sm text-flapjack-plum">{searchError}</p>
			<button
				type="button"
				class="rounded-md border border-flapjack-plum px-3 py-1 text-sm text-flapjack-plum hover:bg-flapjack-cream"
				onclick={() => void runSearch(query)}
			>
				Retry
			</button>
		</div>
	{/if}

	<button
		type="button"
		class="w-full rounded-md border border-flapjack-ink/20 px-3 py-2 text-sm font-medium text-flapjack-ink md:hidden"
		aria-expanded={mobileRefineOpen}
		onclick={(event) => void openMobileRefine(event.currentTarget)}
	>
		Refine ({filters.length})
	</button>

	<div
		class="grid items-start gap-6 md:grid-cols-[minmax(240px,280px)_minmax(0,1fr)]"
		data-testid="search-layout"
	>
		<div
			class="sticky top-4 hidden overflow-y-auto overscroll-contain pr-1 md:block"
			style="max-height: calc(100vh - 2rem)"
			data-testid="search-refine-sidebar"
		>
			<SearchPreviewFacets
				panels={facetPanels}
				configurationKnown={configuredFacets !== null}
				onToggleFacetValue={handleToggleFacetValue}
				onClearFacetAttribute={handleClearFacetAttribute}
				onClearAllFacets={handleClearAllFacets}
			/>
		</div>

		<div class="min-w-0" data-testid="instantsearch-hits">
			<SearchPreviewResults
				{nbHits}
				{processingTimeMS}
				{hits}
				{page}
				{totalPages}
				{loading}
				{titleField}
				{subtitleField}
				{imageField}
				{tagsField}
				{showJsonView}
				{query}
				{hitsPerPage}
				{indexName}
				merchMode={merchModeEnabled}
				{pinnedPositions}
				hasActiveFilters={filters.length > 0 || filterExpression.trim().length > 0}
				onPageChange={handlePageChange}
				onHitsPerPageChange={handleHitsPerPageChange}
				onClearFilters={handleClearAllFilters}
				onHitClick={handleResultClick}
			/>
		</div>
	</div>

	{#if mobileRefineOpen}
		<div class="fixed inset-0 z-40 md:hidden">
			<button
				type="button"
				class="absolute inset-0 bg-flapjack-ink/45"
				aria-label="Close Refine"
				onclick={() => void closeMobileRefine()}
			></button>
			<dialog
				bind:this={mobileRefineDialog}
				open
				class="absolute inset-y-0 left-0 w-[min(85vw,320px)] overflow-y-auto bg-white p-4 shadow-xl"
				aria-label="Refine results"
				onkeydown={handleMobileRefineKeydown}
			>
				<div class="mb-4 flex items-center justify-between">
					<h2 class="font-semibold text-flapjack-ink">Refine results</h2>
					<button
						type="button"
						data-testid="refine-drawer-close"
						class="rounded px-2 py-1 text-sm hover:bg-flapjack-cream"
						onclick={() => void closeMobileRefine()}>Close</button
					>
				</div>
				<SearchPreviewFacets
					panels={facetPanels}
					configurationKnown={configuredFacets !== null}
					onToggleFacetValue={handleToggleFacetValue}
					onClearFacetAttribute={handleClearFacetAttribute}
					onClearAllFacets={handleClearAllFacets}
				/>
			</dialog>
		</div>
	{/if}
</div>
