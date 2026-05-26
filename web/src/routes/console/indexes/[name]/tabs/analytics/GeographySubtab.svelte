<script lang="ts">
	import { browser } from '$app/environment';
	import { enhance } from '$app/forms';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { SvelteURLSearchParams } from 'svelte/reactivity';
	import type { AnalyticsCountriesResponse } from '$lib/api/types';
	import { countryFlag, COUNTRY_NAMES } from '$lib/analytics/country_names';
	import { formatNumber } from '$lib/format';

	type Props = {
		startDate: string;
		endDate: string;
	};

	type CountryCountByCode = Record<string, number>;
	type CountryRow = {
		code: string;
		count: number;
		share: number;
	};

	let { startDate, endDate }: Props = $props();
	let formElement = $state<HTMLFormElement | null>(null);
	let isLoading = $state(false);
	let hasLoaded = $state(false);
	let countriesError = $state('');
	let countryCounts = $state<CountryCountByCode>({});

	const selectedCountryCode = $derived.by(() => {
		return ((page.state, page.url.searchParams.get('country')) ?? '').toUpperCase();
	});
	const totalSearches = $derived(
		Object.values(countryCounts).reduce((totalCount, count) => totalCount + count, 0)
	);
	const distinctCountryCount = $derived(Object.keys(countryCounts).length);
	const countryRows = $derived.by<CountryRow[]>(() => {
		const total = totalSearches;
		return Object.entries(countryCounts)
			.map(([code, count]) => ({
				code,
				count,
				share: total > 0 ? (count / total) * 100 : 0
			}))
			.sort((left, right) => right.count - left.count);
	});

	const selectedCountryName = $derived(COUNTRY_NAMES[selectedCountryCode] ?? selectedCountryCode);

	function toNumberCount(value: unknown): number {
		return typeof value === 'number' && Number.isFinite(value) ? value : 0;
	}

	function parseCountryCounts(payload: AnalyticsCountriesResponse | null | undefined): CountryCountByCode {
		if (!payload || typeof payload !== 'object') return {};
		const rawCountries = payload.countries ?? {};
		const parsedCountries: CountryCountByCode = {};
		for (const [code, count] of Object.entries(rawCountries)) {
			parsedCountries[code.toUpperCase()] = toNumberCount(count);
		}
		return parsedCountries;
	}

	function readAnalyticsCountriesPayload(
		resultData: unknown
	): AnalyticsCountriesResponse | null | undefined {
		if (!resultData || typeof resultData !== 'object') return null;
		return (resultData as { analyticsCountries?: AnalyticsCountriesResponse }).analyticsCountries;
	}

	function submitCountriesForm() {
		if (!formElement || !startDate || !endDate) return;
		isLoading = true;
		countriesError = '';
		formElement.requestSubmit();
	}

	function hrefWithCountryCode(countryCode: string | null): string {
		const nextSearchParams = new SvelteURLSearchParams(page.url.searchParams);
		if (countryCode) {
			nextSearchParams.set('country', countryCode.toUpperCase());
		} else {
			nextSearchParams.delete('country');
		}
		const queryString = nextSearchParams.toString();
		return queryString ? `${page.url.pathname}?${queryString}` : page.url.pathname;
	}

	function navigateWithCountryCode(countryCode: string | null) {
		if (!browser) return;
		// eslint-disable-next-line svelte/no-navigation-without-resolve
		void goto(hrefWithCountryCode(countryCode), {
			keepFocus: true,
			noScroll: true
		});
	}

	function activateCountryDrilldown(countryCode: string) {
		navigateWithCountryCode(countryCode);
	}

	function clearCountryDrilldown() {
		navigateWithCountryCode(null);
	}

	function retryFetch() {
		submitCountriesForm();
	}

	$effect(() => {
		if (!startDate || !endDate) return;
		submitCountriesForm();
	});
</script>

<form
	class="hidden"
	method="POST"
	action="?/fetchAnalyticsCountries"
	bind:this={formElement}
	use:enhance={({ formData }) => {
		formData.set('startDate', startDate);
		formData.set('endDate', endDate);
		return async ({ result }) => {
			hasLoaded = true;
			isLoading = false;

			if (result.type === 'success') {
				countriesError = '';
				countryCounts = parseCountryCounts(readAnalyticsCountriesPayload(result.data));
				return;
			}

			const failureData =
				result.type === 'failure'
					? (result.data as { analyticsCountriesError?: string } | null)
					: null;
			countriesError = failureData?.analyticsCountriesError ?? 'Failed to load geography analytics';
			countryCounts = {};
		};
	}}
>
	<input type="hidden" name="startDate" value={startDate} />
	<input type="hidden" name="endDate" value={endDate} />
</form>

<section class="rounded-lg border border-flapjack-ink/20 p-4" data-testid="analytics-subtab-panel-geography">
	<h3 class="mb-4 text-sm font-semibold text-flapjack-ink">Geography</h3>

		{#if selectedCountryCode}
			<div class="space-y-4" data-testid="geo-country-detail">
				<button
					type="button"
					class="text-sm font-medium text-flapjack-rose hover:text-flapjack-plum"
					data-testid="geo-country-back"
					onclick={clearCountryDrilldown}
				>
					Back to countries
				</button>

			<h3 class="text-lg font-semibold text-flapjack-ink">
				{countryFlag(selectedCountryCode)} {selectedCountryName}
			</h3>
			<p class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/70 p-4 text-sm text-flapjack-ink/80">
				Top searches from {selectedCountryName}
			</p>
		</div>
	{:else}
		{#if isLoading && !hasLoaded}
			<div class="space-y-4" data-testid="geo-loading-skeleton">
				<div class="animate-pulse rounded-lg border border-flapjack-ink/20 p-4">
					<div class="h-4 w-24 rounded bg-flapjack-ink/20"></div>
					<div class="mt-3 h-8 w-16 rounded bg-flapjack-ink/15"></div>
				</div>
				<div class="animate-pulse rounded-lg border border-flapjack-ink/20 p-4">
					<div class="h-4 w-40 rounded bg-flapjack-ink/20"></div>
					<div class="mt-3 h-52 rounded bg-flapjack-ink/10"></div>
				</div>
			</div>
		{:else}
			{#if countriesError}
				<div
					role="alert"
					class="mb-4 rounded-md border border-flapjack-rose/35 bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
				>
					<p>{countriesError}</p>
					<button
						type="button"
						class="mt-2 rounded border border-flapjack-rose/50 px-3 py-1 text-xs font-medium text-flapjack-plum hover:bg-flapjack-rose/15"
						onclick={retryFetch}
					>
						Retry
					</button>
				</div>
			{/if}

			{#if countryRows.length === 0}
				<div class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4 text-sm text-flapjack-ink/70">
					No country analytics were recorded for this date range.
				</div>
			{:else}
				<div class="mb-4 rounded-lg border border-flapjack-ink/20 p-4" data-testid="geo-countries-count">
					<p class="text-xs font-medium uppercase tracking-wide text-flapjack-ink/60">Countries</p>
					<p class="mt-1 text-3xl font-semibold text-flapjack-ink">{formatNumber(distinctCountryCount)}</p>
				</div>

				<div class="overflow-x-auto rounded-lg border border-flapjack-ink/20" data-testid="geo-countries-table">
					<table class="w-full text-left text-sm">
						<thead class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60">
							<tr>
								<th class="px-3 py-2">Country</th>
								<th class="px-3 py-2 text-right">Searches</th>
								<th class="px-3 py-2 text-right">Share</th>
							</tr>
						</thead>
						<tbody class="divide-y">
							{#each countryRows as row (row.code)}
								<tr
									class="cursor-pointer hover:bg-flapjack-cream/40"
									data-testid={`geo-country-row-${row.code}`}
									onclick={() => activateCountryDrilldown(row.code)}
								>
									<td class="px-3 py-2">
										<span>{countryFlag(row.code)}</span>
										<span class="ml-2 font-medium text-flapjack-ink">{COUNTRY_NAMES[row.code] ?? row.code}</span>
										<span class="ml-1 text-xs text-flapjack-ink/60">({row.code})</span>
									</td>
									<td class="px-3 py-2 text-right tabular-nums text-flapjack-ink">
										{formatNumber(row.count)}
									</td>
									<td class="px-3 py-2 text-right tabular-nums text-flapjack-ink/80">
										{row.share.toFixed(1)}%
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{/if}
		{/if}
	{/if}
</section>
