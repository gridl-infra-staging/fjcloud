<script lang="ts">
	import { enhance } from '$app/forms';
	import { SvelteSet } from 'svelte/reactivity';
	import { formatNumber } from '$lib/format';
	import type { AnalyticsFilterValuesResponse, AnalyticsCountByKey } from '$lib/api/types';

	type Props = {
		startDate: string;
		endDate: string;
	};

	type FilterValue = {
		key: string;
		count: number;
	};

	type FilterAttributeRow = {
		attribute: string;
		appliedCount: number;
		values: FilterValue[];
	};

	const MAX_EXPANDED_VALUES = 10;

	let { startDate, endDate }: Props = $props();
	let formElement = $state<HTMLFormElement | null>(null);
	let isLoading = $state(false);
	let hasLoaded = $state(false);
	let filtersError = $state('');
	let rawFilters = $state<Record<string, AnalyticsCountByKey>>({});
	let expandedAttributes = new SvelteSet<string>();

	const filterRows = $derived.by<FilterAttributeRow[]>(() => {
		return Object.entries(rawFilters)
			.map(([attribute, valueCounts]) => {
				const values: FilterValue[] = Object.entries(valueCounts)
					.map(([key, count]) => ({ key, count: toNumberCount(count) }))
					.sort((a, b) => b.count - a.count);
				const appliedCount = values.reduce((sum, v) => sum + v.count, 0);
				return { attribute, appliedCount, values: values.slice(0, MAX_EXPANDED_VALUES) };
			})
			.sort((a, b) => b.appliedCount - a.appliedCount);
	});

	function toNumberCount(value: unknown): number {
		return typeof value === 'number' && Number.isFinite(value) ? value : 0;
	}

	function parseFiltersPayload(
		payload: AnalyticsFilterValuesResponse | null | undefined
	): Record<string, AnalyticsCountByKey> | null {
		if (!payload || typeof payload !== 'object') return null;
		if (!('filters' in payload) || !payload.filters || typeof payload.filters !== 'object') {
			return null;
		}
		return payload.filters;
	}

	function readAnalyticsFiltersPayload(
		resultData: unknown
	): AnalyticsFilterValuesResponse | null | undefined {
		if (!resultData || typeof resultData !== 'object') return null;
		return (resultData as { analyticsFilters?: AnalyticsFilterValuesResponse }).analyticsFilters;
	}

	function submitFiltersForm() {
		if (!formElement || !startDate || !endDate) return;
		isLoading = true;
		filtersError = '';
		formElement.requestSubmit();
	}

	function toggleAttribute(attribute: string) {
		// Keep one reactive SvelteSet instance and mutate it in place.
		// Reassigning a plain `let` in runes mode does not trigger updates.
		if (expandedAttributes.has(attribute)) {
			expandedAttributes.delete(attribute);
		} else {
			expandedAttributes.add(attribute);
		}
	}

	function retryFetch() {
		submitFiltersForm();
	}

	$effect(() => {
		if (!startDate || !endDate) return;
		submitFiltersForm();
	});
</script>

<form
	class="hidden"
	method="POST"
	action="?/fetchAnalyticsFilters"
	bind:this={formElement}
	use:enhance={({ formData }) => {
		formData.set('startDate', startDate);
		formData.set('endDate', endDate);
		return async ({ result }) => {
			hasLoaded = true;
			isLoading = false;

			if (result.type === 'success') {
				const parsedFilters = parseFiltersPayload(readAnalyticsFiltersPayload(result.data));
				if (parsedFilters === null) {
					filtersError = 'Failed to load filter analytics';
					rawFilters = {};
					return;
				}
				filtersError = '';
				rawFilters = parsedFilters;
				return;
			}

			const failureData =
				result.type === 'failure'
					? (result.data as { analyticsFiltersError?: string } | null)
					: null;
			filtersError = failureData?.analyticsFiltersError ?? 'Failed to load filter analytics';
			rawFilters = {};
		};
	}}
>
	<input type="hidden" name="startDate" value={startDate} />
	<input type="hidden" name="endDate" value={endDate} />
</form>

<section
	class="rounded-lg border border-flapjack-ink/20 p-4"
	data-testid="analytics-subtab-panel-filters"
>
	<h3 class="mb-4 text-sm font-semibold text-flapjack-ink">Filters</h3>

	{#if isLoading && !hasLoaded}
		<div class="space-y-3" data-testid="filters-loading-skeleton">
			{#each [1, 2, 3] as skeletonRow (skeletonRow)}
				<div class="animate-pulse rounded-lg border border-flapjack-ink/20 p-4">
					<div class="h-4 w-32 rounded bg-flapjack-ink/20"></div>
					<div class="mt-2 h-4 w-16 rounded bg-flapjack-ink/15"></div>
				</div>
			{/each}
		</div>
	{:else}
		{#if filtersError}
			<div
				role="alert"
				class="mb-4 rounded-md border border-flapjack-rose/35 bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
			>
				<p>{filtersError}</p>
				<button
					type="button"
					class="mt-2 rounded border border-flapjack-rose/50 px-3 py-1 text-xs font-medium text-flapjack-plum hover:bg-flapjack-rose/15"
					onclick={retryFetch}
				>
					Retry
				</button>
			</div>
		{/if}

		{#if filterRows.length === 0}
			<div
				class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4 text-sm text-flapjack-ink/70"
			>
				No filter analytics were recorded for this date range.
			</div>
		{:else}
			<div
				class="overflow-x-auto rounded-lg border border-flapjack-ink/20"
				data-testid="filters-table"
			>
				<table class="w-full text-left text-sm">
					<thead
						class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
					>
						<tr>
							<th class="px-3 py-2">Filter attribute</th>
							<th class="px-3 py-2 text-right">Applied count</th>
						</tr>
					</thead>
					<tbody class="divide-y">
						{#each filterRows as row (row.attribute)}
							<tr
								class="cursor-pointer hover:bg-flapjack-cream/40"
								data-testid={`filter-row-${row.attribute}`}
								onclick={() => toggleAttribute(row.attribute)}
							>
								<td class="px-3 py-2 font-medium text-flapjack-ink">{row.attribute}</td>
								<td class="px-3 py-2 text-right tabular-nums text-flapjack-ink">
									{formatNumber(row.appliedCount)}
								</td>
							</tr>
							{#if expandedAttributes.has(row.attribute)}
								<tr>
									<td colspan="2" class="px-3 py-2">
										<div
											class="rounded-md border border-flapjack-ink/10 bg-flapjack-cream/50 p-3"
											data-testid={`filter-values-${row.attribute}`}
										>
											<p
												class="mb-2 text-xs font-semibold uppercase tracking-wide text-flapjack-ink/60"
											>
												{row.attribute}
											</p>
											<ul class="space-y-1 text-sm text-flapjack-ink/80">
												{#each row.values as v (v.key)}
													<li>{v.key} ({formatNumber(v.count)})</li>
												{/each}
											</ul>
										</div>
									</td>
								</tr>
							{/if}
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	{/if}
</section>
