<script lang="ts">
	import { browser } from '$app/environment';
	import { goto } from '$app/navigation';
	import { AreaChart } from 'layerchart';
	import { formatNumber } from '$lib/format';
	import type {
		AnalyticsNoResultRateResponse,
		AnalyticsSearchCountResponse,
		AnalyticsStatusResponse,
		AnalyticsTopSearch,
		AnalyticsTopSearchesResponse
	} from '$lib/api/types';

	type Props = {
		searchCount: AnalyticsSearchCountResponse | null;
		noResultRate: AnalyticsNoResultRateResponse | null;
		topSearches: AnalyticsTopSearchesResponse | null;
		noResults: AnalyticsTopSearchesResponse | null;
		analyticsStatus: AnalyticsStatusResponse | null;
		analyticsPeriod: '7d' | '30d' | '90d';
		analyticsUnavailable: boolean;
	};

	let {
		searchCount,
		noResultRate,
		topSearches,
		noResults,
		analyticsStatus,
		analyticsPeriod,
		analyticsUnavailable
	}: Props = $props();

	let analyticsLoading = $state(false);
	const resolvedSearchCount = $derived(searchCount ?? { count: 0, dates: [] });
	const resolvedNoResultRate = $derived(noResultRate ?? { rate: 0, noResults: 0 });
	const topSearchEntries = $derived(topSearches?.searches ?? []);
	const noResultEntries = $derived(noResults?.searches ?? []);

	function formatRatePercent(rate: number | null | undefined): string {
		if (rate === null || rate === undefined) return '0.0%';
		return `${(rate * 100).toFixed(1)}%`;
	}

	function formatAvgHits(entry: AnalyticsTopSearch): string {
		if (entry.count <= 0) return '0.00';
		return (entry.nbHits / entry.count).toFixed(2);
	}

	function selectAnalyticsPeriod(period: '7d' | '30d' | '90d') {
		if (period === analyticsPeriod) return;
		analyticsLoading = true;
		// eslint-disable-next-line svelte/no-navigation-without-resolve
		goto(`?period=${period}`);
	}

	$effect(() => {
		if (analyticsPeriod) analyticsLoading = false;
	});
</script>

		<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="analytics-section">
			<h2 class="mb-4 text-lg font-medium text-gray-900">Analytics</h2>

			<div class="mb-4 inline-flex rounded-md border border-gray-200 bg-gray-50 p-1">
				<button
					type="button"
					onclick={() => selectAnalyticsPeriod('7d')}
					class="rounded px-3 py-1.5 text-sm font-medium {analyticsPeriod === '7d' ? 'bg-blue-600 text-white' : 'text-gray-700 hover:bg-gray-100'}"
				>
					7d
				</button>
				<button
					type="button"
					onclick={() => selectAnalyticsPeriod('30d')}
					class="rounded px-3 py-1.5 text-sm font-medium {analyticsPeriod === '30d' ? 'bg-blue-600 text-white' : 'text-gray-700 hover:bg-gray-100'}"
				>
					30d
				</button>
				<button
					type="button"
					onclick={() => selectAnalyticsPeriod('90d')}
					class="rounded px-3 py-1.5 text-sm font-medium {analyticsPeriod === '90d' ? 'bg-blue-600 text-white' : 'text-gray-700 hover:bg-gray-100'}"
				>
					90d
				</button>
			</div>

			{#if analyticsLoading}
				<div class="rounded-md border border-gray-200 bg-gray-50 p-4 text-sm text-gray-600">
					Loading analytics...
				</div>
			{:else if analyticsUnavailable}
					<div class="rounded-md border border-gray-200 bg-gray-50 p-4">
						<p class="mb-1 font-medium text-gray-900">Analytics not available</p>
						<p class="text-sm text-gray-600">
							{analyticsStatus?.enabled === false
								? 'Analytics is disabled for this index.'
								: 'Analytics requires search traffic. Data will appear once your index receives queries.'}
						</p>
					</div>
			{:else}
				<div class="mb-6 grid grid-cols-1 gap-4 md:grid-cols-2">
					<div class="rounded-lg border border-gray-200 p-4">
						<p class="text-sm font-medium text-gray-500">Total Searches</p>
						<p class="mt-1 text-3xl font-semibold text-gray-900">{formatNumber(resolvedSearchCount.count)}</p>
					</div>
					<div class="rounded-lg border border-gray-200 p-4">
						<p class="text-sm font-medium text-gray-500">No-Result Rate</p>
						<p class="mt-1 text-3xl font-semibold text-gray-900">{formatRatePercent(resolvedNoResultRate.rate)}</p>
						<p class="mt-1 text-sm text-gray-600">{formatNumber(resolvedNoResultRate.noResults)} no-result searches</p>
					</div>
				</div>

				<div class="mb-6 rounded-lg border border-gray-200 p-4" data-testid="analytics-volume-chart">
					<h3 class="mb-3 text-sm font-semibold text-gray-900">Search Volume</h3>
					{#if browser}
						<div class="h-64">
							<AreaChart data={resolvedSearchCount.dates} x="date" y="count" />
						</div>
					{:else}
						<table class="w-full text-left text-sm">
							<thead class="border-b bg-gray-50 text-xs font-medium uppercase text-gray-500">
								<tr>
									<th class="px-3 py-2">Date</th>
									<th class="px-3 py-2">Searches</th>
								</tr>
							</thead>
							<tbody class="divide-y">
								{#each resolvedSearchCount.dates as day (day.date)}
									<tr>
										<td class="px-3 py-2 text-gray-700">{day.date}</td>
										<td class="px-3 py-2 text-gray-900">{formatNumber(day.count)}</td>
									</tr>
								{/each}
							</tbody>
						</table>
					{/if}
				</div>

				<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
					<div class="rounded-lg border border-gray-200 p-4">
						<h3 class="mb-3 text-sm font-semibold text-gray-900">Top Searches</h3>
						<table class="w-full text-left text-sm">
							<thead class="border-b bg-gray-50 text-xs font-medium uppercase text-gray-500">
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
										<td class="px-3 py-2 text-gray-700">{idx + 1}</td>
										<td class="px-3 py-2 text-gray-900">{entry.search}</td>
										<td class="px-3 py-2 text-gray-900">{formatNumber(entry.count)}</td>
										<td class="px-3 py-2 text-gray-700">{formatAvgHits(entry)}</td>
									</tr>
								{/each}
							</tbody>
						</table>
					</div>

					<div class="rounded-lg border border-gray-200 p-4">
						<h3 class="mb-3 text-sm font-semibold text-gray-900">No-Result Queries</h3>
						{#if noResultEntries.length === 0}
							<p class="text-sm text-gray-500">No data</p>
						{:else}
							<table class="w-full text-left text-sm">
								<thead class="border-b bg-gray-50 text-xs font-medium uppercase text-gray-500">
									<tr>
										<th class="px-3 py-2">Rank</th>
										<th class="px-3 py-2">Query</th>
										<th class="px-3 py-2">Count</th>
									</tr>
								</thead>
								<tbody class="divide-y">
									{#each noResultEntries as entry, idx (`${entry.search}-${idx}`)}
										<tr>
											<td class="px-3 py-2 text-gray-700">{idx + 1}</td>
											<td class="px-3 py-2 text-gray-900">{entry.search}</td>
											<td class="px-3 py-2 text-gray-900">{formatNumber(entry.count)}</td>
										</tr>
									{/each}
								</tbody>
							</table>
						{/if}
					</div>
				</div>
			{/if}
		</div>
