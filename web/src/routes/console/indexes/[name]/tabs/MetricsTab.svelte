<script lang="ts">
	import { invalidate } from '$app/navigation';
	import { formatBytes, formatNumber, formatRelativeTime } from '$lib/format';
	import type { IndexMetricsResponse } from '$lib/api/types';
	import { metricsDependencyKey } from '../metrics-keys';
	import { INDEX_DETAIL_TAB_PANEL_TEST_IDS } from '../index_detail_tabs';

	type MetricsError = {
		code: number;
		message: string;
	};

	type Props = {
		metrics: IndexMetricsResponse | null;
		error: MetricsError | null;
		indexName: string;
	};

	let { metrics, error, indexName }: Props = $props();

	let refreshInFlight = $state(false);

	const isEmptyMetrics = $derived(
		metrics !== null &&
			metrics.documents_count === 0 &&
			metrics.search_requests_total === 0 &&
			metrics.write_operations_total === 0
	);
	const fetchedAtRelativeLabel = $derived(
		metrics?.fetched_at ? formatRelativeTime(metrics.fetched_at) : '\u2014'
	);

	type KpiCard = {
		label: string;
		value: string;
		testId: string;
	};

	const kpiCards = $derived<KpiCard[]>(
		metrics === null
			? []
			: [
					{
						label: 'Documents',
						value: formatNumber(metrics.documents_count),
						testId: 'metrics-kpi-documents'
					},
					{
						label: 'Storage',
						value: formatBytes(metrics.storage_bytes),
						testId: 'metrics-kpi-storage'
					},
					{
						label: 'Search requests',
						value: formatNumber(metrics.search_requests_total),
						testId: 'metrics-kpi-search-requests'
					},
					{
						label: 'Write operations',
						value: formatNumber(metrics.write_operations_total),
						testId: 'metrics-kpi-write-operations'
					}
				]
	);

	async function refreshMetrics(): Promise<void> {
		if (refreshInFlight) return;

		refreshInFlight = true;
		try {
			// This tab owns a dedicated dependency key so refreshes do not need to
			// invalidate every other index-detail payload slice.
			await invalidate(metricsDependencyKey(indexName));
		} finally {
			refreshInFlight = false;
		}
	}
</script>

<section class="space-y-4" data-testid={INDEX_DETAIL_TAB_PANEL_TEST_IDS.metrics}>
	<div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
		<div class="space-y-2">
			<h2 class="text-lg font-medium text-flapjack-ink">Metrics</h2>
			<p class="max-w-3xl text-sm text-flapjack-ink/70">
				These counters come from the engine scrape for this index. They measure raw document,
				storage, search, and write activity rather than the customer-behavior analytics shown on the
				Analytics tab.
			</p>
		</div>
		<div class="flex flex-col items-start gap-2 sm:items-end">
			<button
				type="button"
				class="rounded-md border border-flapjack-ink/25 px-3 py-1.5 text-sm font-medium text-flapjack-ink hover:bg-flapjack-cream/70 disabled:cursor-not-allowed disabled:opacity-50"
				data-testid="metrics-refresh-btn"
				disabled={refreshInFlight}
				onclick={() => {
					void refreshMetrics();
				}}
			>
				{refreshInFlight ? 'Refreshing...' : 'Refresh'}
			</button>
			{#if metrics}
				<p
					class="text-sm text-flapjack-ink/70"
					data-testid="metrics-fetched-at"
					title={metrics.fetched_at}
				>
					Last fetched {fetchedAtRelativeLabel}
				</p>
			{/if}
		</div>
	</div>

	{#if error}
		<!-- Keep metrics failures local to this tab so the rest of the detail route stays usable. -->
		<div class="rounded-md border border-flapjack-rose/30 bg-flapjack-rose/10 p-4" role="alert">
			<p class="font-medium text-flapjack-ink">Metrics unavailable</p>
			<p class="mt-1 text-sm text-flapjack-ink/80">
				{error.message} (HTTP {error.code}). Retry to fetch a fresh metrics snapshot.
			</p>
		</div>
	{:else if metrics}
		<div
			class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4"
			data-testid="metrics-kpi-grid"
		>
			{#each kpiCards as card (card.testId)}
				<div
					class="rounded-lg border border-flapjack-ink/10 bg-white/90 p-4 shadow-sm"
					data-testid={card.testId}
				>
					<p class="text-xs uppercase tracking-wide text-flapjack-ink/60">{card.label}</p>
					<p class="mt-2 text-2xl font-semibold text-flapjack-ink">{card.value}</p>
				</div>
			{/each}
		</div>

		{#if isEmptyMetrics}
			<div
				class="rounded-md border border-dashed border-flapjack-ink/20 bg-flapjack-cream/40 p-4 text-sm text-flapjack-ink/75"
				data-testid="metrics-empty-state"
			>
				No metrics available yet - newly-created indexes report stats after the first scrape
				interval (60s).
			</div>
		{/if}
	{/if}
</section>
