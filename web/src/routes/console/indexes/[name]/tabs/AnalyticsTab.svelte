<script lang="ts">
	import { browser } from '$app/environment';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { SvelteURLSearchParams } from 'svelte/reactivity';
	import type {
		AnalyticsNoResultRateResponse,
		AnalyticsSearchCountResponse,
		AnalyticsStatusResponse,
		AnalyticsTopSearchesResponse
	} from '$lib/api/types';
	import ConversionsSubtab from './analytics/ConversionsSubtab.svelte';
	import DevicesSubtab from './analytics/DevicesSubtab.svelte';
	import FiltersSubtab from './analytics/FiltersSubtab.svelte';
	import GeographySubtab from './analytics/GeographySubtab.svelte';
	import NoResultsSubtab from './analytics/NoResultsSubtab.svelte';
	import OverviewSubtab from './analytics/OverviewSubtab.svelte';
	import SearchesSubtab from './analytics/SearchesSubtab.svelte';

	type Props = {
		searchCount: AnalyticsSearchCountResponse | null;
		noResultRate: AnalyticsNoResultRateResponse | null;
		topSearches: AnalyticsTopSearchesResponse | null;
		noResults: AnalyticsTopSearchesResponse | null;
		analyticsStatus: AnalyticsStatusResponse | null;
		analyticsPeriod: '7d' | '30d' | '90d';
		startDate: string;
		endDate: string;
		analyticsUnavailable: boolean;
	};

	type AnalyticsPeriod = Props['analyticsPeriod'];

	type AnalyticsSubtabId =
		| 'overview'
		| 'searches'
		| 'no-results'
		| 'filters'
		| 'conversions'
		| 'devices'
		| 'geography';

	type AnalyticsSubtabDefinition = {
		id: AnalyticsSubtabId;
		label: string;
		testId: string;
	};

	const ANALYTICS_SUBTAB_DEFINITIONS: readonly AnalyticsSubtabDefinition[] = [
		{ id: 'overview', label: 'Overview', testId: 'analytics-subtab-overview' },
		{ id: 'searches', label: 'Searches', testId: 'analytics-subtab-searches' },
		{ id: 'no-results', label: 'No Results', testId: 'analytics-subtab-no-results' },
		{ id: 'filters', label: 'Filters', testId: 'analytics-subtab-filters' },
		{ id: 'conversions', label: 'Conversions', testId: 'analytics-subtab-conversions' },
		{ id: 'devices', label: 'Devices', testId: 'analytics-subtab-devices' },
		{ id: 'geography', label: 'Geography', testId: 'analytics-subtab-geography' }
	] as const;

	const ANALYTICS_PERIOD_OPTIONS: readonly AnalyticsPeriod[] = ['7d', '30d', '90d'];

	const analyticsSubtabIds = new Set<AnalyticsSubtabId>(
		ANALYTICS_SUBTAB_DEFINITIONS.map((subtab) => subtab.id)
	);

	let {
		searchCount,
		noResultRate,
		topSearches,
		noResults,
		analyticsStatus,
		analyticsPeriod,
		startDate,
		endDate,
		analyticsUnavailable
	}: Props = $props();

	let analyticsLoading = $state(false);
	let activeSubtab = $state<AnalyticsSubtabId>(parseAnalyticsSubtabFromUrl(page.url));

	function parseAnalyticsSubtabFromUrl(currentUrl: URL): AnalyticsSubtabId {
		const rawSubtab = currentUrl.searchParams.get('subtab');
		if (rawSubtab && analyticsSubtabIds.has(rawSubtab as AnalyticsSubtabId)) {
			return rawSubtab as AnalyticsSubtabId;
		}
		return 'overview';
	}

	function analyticsSearchParamsWithoutLegacyDates(): SvelteURLSearchParams {
		const nextSearchParams = new SvelteURLSearchParams(page.url.searchParams);
		// `period` is the single owner of the analytics window. Remove the old
		// explicit date params so subtab/period navigation cannot reintroduce a
		// misleading second source of truth into the URL.
		nextSearchParams.delete('startDate');
		nextSearchParams.delete('endDate');
		return nextSearchParams;
	}

	function navigateAnalyticsWithParam(key: 'period' | 'subtab', value: AnalyticsPeriod | AnalyticsSubtabId) {
		const nextSearchParams = analyticsSearchParamsWithoutLegacyDates();
		nextSearchParams.set(key, value);
		// eslint-disable-next-line svelte/no-navigation-without-resolve
		void goto(`${page.url.pathname}?${nextSearchParams.toString()}`, {
			keepFocus: true,
			noScroll: true
		});
	}

	function selectAnalyticsPeriod(period: AnalyticsPeriod) {
		if (period === analyticsPeriod) return;
		analyticsLoading = true;
		navigateAnalyticsWithParam('period', period);
	}

	function activateAnalyticsSubtab(subtab: AnalyticsSubtabId) {
		if (!browser) return;
		if (subtab === parseAnalyticsSubtabFromUrl(page.url)) {
			activeSubtab = subtab;
			return;
		}

		navigateAnalyticsWithParam('subtab', subtab);
	}

	$effect(() => {
		if (analyticsPeriod) analyticsLoading = false;
	});

	$effect(() => {
		const nextSubtab = parseAnalyticsSubtabFromUrl(page.url);
		if (nextSubtab !== activeSubtab) {
			activeSubtab = nextSubtab;
		}
	});
</script>

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="analytics-section">
	<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Analytics</h2>

	<div class="mb-4 inline-flex rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-1">
		{#each ANALYTICS_PERIOD_OPTIONS as period (period)}
			<button
				type="button"
				onclick={() => selectAnalyticsPeriod(period)}
				class="rounded px-3 py-1.5 text-sm font-medium {analyticsPeriod === period
					? 'bg-flapjack-rose text-white'
					: 'text-flapjack-ink/80 hover:bg-flapjack-cream/70'}"
			>
				{period}
			</button>
		{/each}
	</div>

	<div
		role="tablist"
		aria-label="Analytics sections"
		data-testid="analytics-subtabs-strip"
		class="mb-4 flex flex-wrap gap-2"
	>
		{#each ANALYTICS_SUBTAB_DEFINITIONS as subtab (subtab.id)}
			<button
				type="button"
				role="tab"
				aria-selected={activeSubtab === subtab.id}
				data-testid={subtab.testId}
				onclick={() => activateAnalyticsSubtab(subtab.id)}
				class="rounded-md border px-3 py-1.5 text-sm font-medium {activeSubtab === subtab.id
					? 'border-flapjack-rose bg-flapjack-rose text-white'
					: 'border-flapjack-ink/30 text-flapjack-ink/80 hover:bg-flapjack-cream/70'}"
			>
				{subtab.label}
			</button>
		{/each}
	</div>

	{#if activeSubtab === 'overview'}
		<OverviewSubtab
			{searchCount}
			{noResultRate}
			{topSearches}
			{noResults}
			{analyticsStatus}
			{analyticsUnavailable}
			{analyticsLoading}
		/>
	{:else if activeSubtab === 'searches'}
		<SearchesSubtab />
	{:else if activeSubtab === 'no-results'}
		<NoResultsSubtab />
	{:else if activeSubtab === 'filters'}
		<FiltersSubtab {startDate} {endDate} />
	{:else if activeSubtab === 'conversions'}
		<ConversionsSubtab {startDate} {endDate} />
	{:else if activeSubtab === 'devices'}
		<DevicesSubtab {startDate} {endDate} />
	{:else}
		<GeographySubtab {startDate} {endDate} />
	{/if}
</div>
