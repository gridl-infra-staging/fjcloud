<script lang="ts">
	import { browser } from '$app/environment';
	import { AreaChart } from 'layerchart';
	import { formatNumber } from '$lib/format';
	import type {
		AnalyticsNoResultRateResponse,
		AnalyticsSearchCountResponse,
		AnalyticsStatusResponse,
		AnalyticsTopSearch,
		AnalyticsTopSearchesResponse
	} from '$lib/api/types';
	import { formatRatePercent } from '../experiments_tab_helpers';

	type Props = {
		searchCount: AnalyticsSearchCountResponse | null;
		noResultRate: AnalyticsNoResultRateResponse | null;
		topSearches: AnalyticsTopSearchesResponse | null;
		noResults: AnalyticsTopSearchesResponse | null;
		analyticsStatus: AnalyticsStatusResponse | null;
		analyticsUnavailable: boolean;
		analyticsLoading: boolean;
	};

	let {
		searchCount,
		noResultRate,
		topSearches,
		noResults,
		analyticsStatus,
		analyticsUnavailable,
		analyticsLoading
	}: Props = $props();

	const resolvedSearchCount = $derived(searchCount ?? { count: 0, dates: [] });
	const resolvedNoResultRate = $derived(noResultRate ?? { rate: 0, noResults: 0 });
	const topSearchEntries = $derived(topSearches?.searches ?? []);
	const noResultEntries = $derived(noResults?.searches ?? []);

	function formatAvgHits(entry: AnalyticsTopSearch): string {
		if (entry.count <= 0) return '0.00';
		return (entry.nbHits / entry.count).toFixed(2);
	}
</script>

<section data-testid="analytics-subtab-panel-overview">
	{#if analyticsLoading}
		<div
			class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4 text-sm text-flapjack-ink/70"
		>
			Loading analytics...
		</div>
	{:else if analyticsUnavailable}
		<div class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4">
			<p class="mb-1 font-medium text-flapjack-ink">Analytics not available</p>
			<p class="text-sm text-flapjack-ink/70">
				{analyticsStatus?.enabled === false
					? 'Analytics is disabled for this index.'
					: 'Analytics requires search traffic. Data will appear once your index receives queries.'}
			</p>
		</div>
	{:else}
		<div class="mb-6 grid grid-cols-1 gap-4 md:grid-cols-2">
			<div class="rounded-lg border border-flapjack-ink/20 p-4">
				<p class="text-sm font-medium text-flapjack-ink/60">Total Searches</p>
				<p class="mt-1 text-3xl font-semibold text-flapjack-ink">
					{formatNumber(resolvedSearchCount.count)}
				</p>
			</div>
			<div class="rounded-lg border border-flapjack-ink/20 p-4">
				<p class="text-sm font-medium text-flapjack-ink/60">No-Result Rate</p>
				<p class="mt-1 text-3xl font-semibold text-flapjack-ink">
					{formatRatePercent(resolvedNoResultRate.rate)}
				</p>
				<p class="mt-1 text-sm text-flapjack-ink/70">
					{formatNumber(resolvedNoResultRate.noResults)} no-result searches
				</p>
			</div>
		</div>

		<div
			class="mb-6 rounded-lg border border-flapjack-ink/20 p-4"
			data-testid="analytics-volume-chart"
		>
			<h3 class="mb-3 text-sm font-semibold text-flapjack-ink">Search Volume</h3>
			{#if browser}
				<div class="h-64">
					<AreaChart data={resolvedSearchCount.dates} x="date" y="count" />
				</div>
			{:else}
				<table class="w-full text-left text-sm">
					<thead
						class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
					>
						<tr>
							<th class="px-3 py-2">Date</th>
							<th class="px-3 py-2">Searches</th>
						</tr>
					</thead>
					<tbody class="divide-y">
						{#each resolvedSearchCount.dates as day (day.date)}
							<tr>
								<td class="px-3 py-2 text-flapjack-ink/80">{day.date}</td>
								<td class="px-3 py-2 text-flapjack-ink">{formatNumber(day.count)}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			{/if}
		</div>

		<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
			<div class="rounded-lg border border-flapjack-ink/20 p-4">
				<h3 class="mb-3 text-sm font-semibold text-flapjack-ink">Top Searches</h3>
				<table class="w-full text-left text-sm">
					<thead
						class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
					>
						<tr>
							<th class="px-3 py-2">Rank</th>
							<th class="px-3 py-2">Query</th>
							<th class="px-3 py-2">Count</th>
							<th class="px-3 py-2">Avg Hits</th>
						</tr>
					</thead>
					<tbody class="divide-y">
						{#each topSearchEntries as entry, idx (`${entry.search}-${idx}`)}
							<tr>
								<td class="px-3 py-2 text-flapjack-ink/80">{idx + 1}</td>
								<td class="px-3 py-2 text-flapjack-ink">{entry.search}</td>
								<td class="px-3 py-2 text-flapjack-ink">{formatNumber(entry.count)}</td>
								<td class="px-3 py-2 text-flapjack-ink/80">{formatAvgHits(entry)}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>

			<div class="rounded-lg border border-flapjack-ink/20 p-4">
				<h3 class="mb-3 text-sm font-semibold text-flapjack-ink">No-Result Queries</h3>
				{#if noResultEntries.length === 0}
					<p class="text-sm text-flapjack-ink/60">No data</p>
				{:else}
					<table class="w-full text-left text-sm">
						<thead
							class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
						>
							<tr>
								<th class="px-3 py-2">Rank</th>
								<th class="px-3 py-2">Query</th>
								<th class="px-3 py-2">Count</th>
							</tr>
						</thead>
						<tbody class="divide-y">
							{#each noResultEntries as entry, idx (`${entry.search}-${idx}`)}
								<tr>
									<td class="px-3 py-2 text-flapjack-ink/80">{idx + 1}</td>
									<td class="px-3 py-2 text-flapjack-ink">{entry.search}</td>
									<td class="px-3 py-2 text-flapjack-ink">{formatNumber(entry.count)}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				{/if}
			</div>
		</div>
	{/if}
</section>
