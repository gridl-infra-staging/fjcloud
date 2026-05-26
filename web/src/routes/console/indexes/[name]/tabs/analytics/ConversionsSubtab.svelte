<script lang="ts">
	import { browser } from '$app/environment';
	import { enhance } from '$app/forms';
	import { AreaChart } from 'layerchart';
	import type { AnalyticsConversionSubtabPayload, AnalyticsConversionTrendPoint } from '$lib/api/types';
	import { formatRatePercent } from '../experiments_tab_helpers';

	type Props = {
		startDate: string;
		endDate: string;
	};

	type ConversionKpiKey = 'ctr' | 'addToCart' | 'purchase' | 'conversionRate';
	type ConversionKpiCard = {
		key: ConversionKpiKey;
		label: string;
		testId: string;
		deltaTestId: string;
	};

	const KPI_CARDS: readonly ConversionKpiCard[] = [
		{
			key: 'conversionRate',
			label: 'Conversion Rate',
			testId: 'conversion-kpi-conversionRate',
			deltaTestId: 'conversion-kpi-conversionRate-delta'
		},
		{
			key: 'addToCart',
			label: 'Add-to-Cart Rate',
			testId: 'conversion-kpi-addToCart',
			deltaTestId: 'conversion-kpi-addToCart-delta'
		},
		{
			key: 'purchase',
			label: 'Purchase Rate',
			testId: 'conversion-kpi-purchase',
			deltaTestId: 'conversion-kpi-purchase-delta'
		},
		{
			key: 'ctr',
			label: 'Click-through Rate',
			testId: 'conversion-kpi-ctr',
			deltaTestId: 'conversion-kpi-ctr-delta'
		}
	] as const;

	let { startDate, endDate }: Props = $props();
	let formElement = $state<HTMLFormElement | null>(null);
	let isLoading = $state(false);
	let hasLoaded = $state(false);
	let conversionError = $state('');
	let selectedCountry = $state('');
	let conversionPayload = $state<AnalyticsConversionSubtabPayload>(emptyConversionPayload());

	const trendPoints = $derived(conversionPayload.trend);
	const hasTrendPoints = $derived(trendPoints.length > 0);
	const countryOptions = $derived(conversionPayload.countries);
	const noConversionData = $derived(
		KPI_CARDS.every(({ key }) => conversionPayload.kpis[key].current === 0) && !hasTrendPoints
	);

	function emptyConversionPayload(): AnalyticsConversionSubtabPayload {
		const zero = { current: 0, previous: 0, delta: 0 };
		return {
			country: null,
			countries: [],
			trend: [],
			kpis: {
				ctr: { ...zero },
				addToCart: { ...zero },
				purchase: { ...zero },
				conversionRate: { ...zero }
			}
		};
	}

	function toFiniteNumber(value: unknown): number {
		return typeof value === 'number' && Number.isFinite(value) ? value : 0;
	}

	function normalizeTrend(trend: AnalyticsConversionTrendPoint[] | undefined): AnalyticsConversionTrendPoint[] {
		if (!Array.isArray(trend)) return [];
		return trend
			.filter((row) => row && typeof row.date === 'string')
			.map((row) => ({
				date: row.date,
				conversionRate: toFiniteNumber(row.conversionRate)
			}));
	}

	function normalizeConversionPayload(
		payload: AnalyticsConversionSubtabPayload | null | undefined
	): AnalyticsConversionSubtabPayload {
		const fallback = emptyConversionPayload();
		if (!payload || typeof payload !== 'object') return fallback;
		const parsedCountries = Array.isArray(payload.countries)
			? payload.countries.filter((country): country is string => typeof country === 'string')
			: [];
		const normalizedPayload: AnalyticsConversionSubtabPayload = {
			country: typeof payload.country === 'string' && payload.country.length > 0 ? payload.country : null,
			countries: parsedCountries,
			trend: normalizeTrend(payload.trend),
			kpis: {
				ctr: {
					current: toFiniteNumber(payload.kpis?.ctr?.current),
					previous: toFiniteNumber(payload.kpis?.ctr?.previous),
					delta: toFiniteNumber(payload.kpis?.ctr?.delta)
				},
				addToCart: {
					current: toFiniteNumber(payload.kpis?.addToCart?.current),
					previous: toFiniteNumber(payload.kpis?.addToCart?.previous),
					delta: toFiniteNumber(payload.kpis?.addToCart?.delta)
				},
				purchase: {
					current: toFiniteNumber(payload.kpis?.purchase?.current),
					previous: toFiniteNumber(payload.kpis?.purchase?.previous),
					delta: toFiniteNumber(payload.kpis?.purchase?.delta)
				},
				conversionRate: {
					current: toFiniteNumber(payload.kpis?.conversionRate?.current),
					previous: toFiniteNumber(payload.kpis?.conversionRate?.previous),
					delta: toFiniteNumber(payload.kpis?.conversionRate?.delta)
				}
			}
		};
		return normalizedPayload;
	}

	function readAnalyticsConversionRatePayload(
		resultData: unknown
	): AnalyticsConversionSubtabPayload | null | undefined {
		if (!resultData || typeof resultData !== 'object') return null;
		return (resultData as { analyticsConversionRate?: AnalyticsConversionSubtabPayload })
			.analyticsConversionRate;
	}

	function submitConversionsForm() {
		if (!formElement || !startDate || !endDate) return;
		isLoading = true;
		conversionError = '';
		formElement.requestSubmit();
	}

	function formatDelta(delta: number): string {
		const deltaPercentPoints = delta * 100;
		const sign = deltaPercentPoints >= 0 ? '+' : '-';
		return `${sign}${Math.abs(deltaPercentPoints).toFixed(1)}pp vs previous period`;
	}

	function retryFetch() {
		submitConversionsForm();
	}

	$effect(() => {
		if (!startDate || !endDate) return;
		submitConversionsForm();
	});
</script>

<form
	class="hidden"
	method="POST"
	action="?/fetchAnalyticsConversionRate"
	bind:this={formElement}
	use:enhance={({ formData }) => {
		formData.set('startDate', startDate);
		formData.set('endDate', endDate);
		formData.set('country', selectedCountry);
		return async ({ result }) => {
			hasLoaded = true;
			isLoading = false;

			if (result.type === 'success') {
				conversionError = '';
				conversionPayload = normalizeConversionPayload(
					readAnalyticsConversionRatePayload(result.data)
				);
				selectedCountry = conversionPayload.country ?? '';
				return;
			}

			const failureData =
				result.type === 'failure'
					? (result.data as { analyticsConversionRateError?: string } | null)
					: null;
			conversionError =
				failureData?.analyticsConversionRateError ?? 'Failed to load conversion analytics';
			conversionPayload = emptyConversionPayload();
		};
	}}
>
	<input type="hidden" name="startDate" value={startDate} />
	<input type="hidden" name="endDate" value={endDate} />
	<input type="hidden" name="country" value={selectedCountry} />
</form>

<section class="rounded-lg border border-flapjack-ink/20 p-4" data-testid="analytics-subtab-panel-conversions">
	<h3 class="mb-4 text-sm font-semibold text-flapjack-ink">Conversions</h3>

	{#if isLoading && !hasLoaded}
		<div class="space-y-4" data-testid="conversions-loading-skeleton">
			<div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4">
				{#each KPI_CARDS as card (card.key)}
					<div class="animate-pulse rounded-lg border border-flapjack-ink/20 p-4">
						<div class="h-4 w-28 rounded bg-flapjack-ink/20"></div>
						<div class="mt-3 h-8 w-16 rounded bg-flapjack-ink/15"></div>
					</div>
				{/each}
			</div>
			<div class="animate-pulse rounded-lg border border-flapjack-ink/20 p-4">
				<div class="h-4 w-40 rounded bg-flapjack-ink/20"></div>
				<div class="mt-3 h-52 rounded bg-flapjack-ink/10"></div>
			</div>
		</div>
	{:else}
		{#if conversionError}
			<div
				role="alert"
				class="mb-4 rounded-md border border-flapjack-rose/35 bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
			>
				<p>{conversionError}</p>
				<button
					type="button"
					class="mt-2 rounded border border-flapjack-rose/50 px-3 py-1 text-xs font-medium text-flapjack-plum hover:bg-flapjack-rose/15"
					onclick={retryFetch}
				>
					Retry
				</button>
			</div>
		{/if}

		<div class="mb-4 flex flex-col gap-2">
			<label for="conversion-country-filter" class="text-xs font-semibold uppercase tracking-wide text-flapjack-ink/60">
				Country filter
			</label>
			<select
				id="conversion-country-filter"
				data-testid="conversion-country-filter"
				class="w-full rounded-md border border-flapjack-ink/25 px-3 py-2 text-sm text-flapjack-ink md:w-64"
				disabled={isLoading || countryOptions.length === 0}
				bind:value={selectedCountry}
				onchange={submitConversionsForm}
			>
				<option value="">All countries</option>
				{#each countryOptions as countryCode (countryCode)}
					<option value={countryCode}>{countryCode}</option>
				{/each}
			</select>
		</div>

		<div class="mb-6 grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-4">
			{#each KPI_CARDS as card (card.key)}
				<div class="rounded-lg border border-flapjack-ink/20 p-4" data-testid={card.testId}>
					<p class="text-sm font-medium text-flapjack-ink/60">{card.label}</p>
					<p class="mt-1 text-3xl font-semibold text-flapjack-ink">
						{formatRatePercent(conversionPayload.kpis[card.key].current)}
					</p>
					<p class="mt-1 text-xs text-flapjack-ink/70" data-testid={card.deltaTestId}>
						{formatDelta(conversionPayload.kpis[card.key].delta)}
					</p>
				</div>
			{/each}
		</div>

		<div class="rounded-lg border border-flapjack-ink/20 p-4" data-testid="conversion-trend-chart">
			<h4 class="mb-3 text-sm font-semibold text-flapjack-ink">Conversion Trend</h4>
			{#if hasTrendPoints}
				{#if browser}
					<div class="h-64">
						<AreaChart data={trendPoints} x="date" y="conversionRate" />
					</div>
				{:else}
					<table class="w-full text-left text-sm">
						<thead class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60">
							<tr>
								<th class="px-3 py-2">Date</th>
								<th class="px-3 py-2">Conversion Rate</th>
							</tr>
						</thead>
						<tbody class="divide-y">
							{#each trendPoints as row (row.date)}
								<tr>
									<td class="px-3 py-2 text-flapjack-ink/80">{row.date}</td>
									<td class="px-3 py-2 text-flapjack-ink">{formatRatePercent(row.conversionRate)}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				{/if}
			{:else}
				<p class="text-sm text-flapjack-ink/70">No conversion trend data for this date range.</p>
			{/if}
		</div>

		{#if noConversionData}
			<div class="mt-4 rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4 text-sm text-flapjack-ink/70">
				No conversions were recorded for this date range.
			</div>
		{/if}
	{/if}
</section>
