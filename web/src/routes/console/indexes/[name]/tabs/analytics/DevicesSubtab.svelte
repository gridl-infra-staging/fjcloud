<script lang="ts">
	import { browser } from '$app/environment';
	import { enhance } from '$app/forms';
	import { BarChart } from 'layerchart';
	import { scaleBand } from 'd3-scale';
	import { formatNumber } from '$lib/format';
	import type { AnalyticsDevicesResponse } from '$lib/api/types';

	type Props = {
		startDate: string;
		endDate: string;
	};

	type DeviceCounts = {
		desktop: number;
		mobile: number;
		tablet: number;
	};

	const DEFAULT_COUNTS: DeviceCounts = { desktop: 0, mobile: 0, tablet: 0 };

	let { startDate, endDate }: Props = $props();
	let formElement = $state<HTMLFormElement | null>(null);
	let isLoading = $state(false);
	let hasLoaded = $state(false);
	let devicesError = $state('');
	let devices = $state<DeviceCounts>(DEFAULT_COUNTS);

	const chartData = $derived([
		{ device: 'Desktop', count: devices.desktop },
		{ device: 'Mobile', count: devices.mobile },
		{ device: 'Tablet', count: devices.tablet }
	]);
	const allCountsZero = $derived(
		devices.desktop === 0 && devices.mobile === 0 && devices.tablet === 0
	);

	function toNumberCount(value: unknown): number {
		return typeof value === 'number' && Number.isFinite(value) ? value : 0;
	}

	function parseDeviceCounts(payload: AnalyticsDevicesResponse | null | undefined): DeviceCounts {
		if (!payload || typeof payload !== 'object') return DEFAULT_COUNTS;
		const devicePayload = payload.devices ?? {};
		return {
			desktop: toNumberCount(devicePayload.desktop),
			mobile: toNumberCount(devicePayload.mobile),
			tablet: toNumberCount(devicePayload.tablet)
		};
	}

	// `enhance`'s callback always hands us an already-parsed ActionResult, so
	// `result.data` is the action's returned object (devalue-decoded by
	// SvelteKit) — never a raw string. Read it directly.
	function readAnalyticsDevicesPayload(
		resultData: unknown
	): AnalyticsDevicesResponse | null | undefined {
		if (!resultData || typeof resultData !== 'object') return null;
		return (resultData as { analyticsDevices?: AnalyticsDevicesResponse }).analyticsDevices;
	}

	function submitDevicesForm() {
		if (!formElement || !startDate || !endDate) return;
		isLoading = true;
		devicesError = '';
		formElement.requestSubmit();
	}

	$effect(() => {
		if (!startDate || !endDate) return;
		submitDevicesForm();
	});
</script>

<form
	class="hidden"
	method="POST"
	action="?/fetchAnalyticsDevices"
	bind:this={formElement}
	use:enhance={({ formData }) => {
		formData.set('startDate', startDate);
		formData.set('endDate', endDate);
		return async ({ result }) => {
			hasLoaded = true;
			isLoading = false;

			if (result.type === 'success') {
				devicesError = '';
				devices = parseDeviceCounts(readAnalyticsDevicesPayload(result.data));
				return;
			}

			const failureData =
				result.type === 'failure'
					? (result.data as { analyticsDevicesError?: string } | null)
					: null;
			devicesError = failureData?.analyticsDevicesError ?? 'Failed to load device analytics';
			devices = DEFAULT_COUNTS;
		};
	}}
>
	<input type="hidden" name="startDate" value={startDate} />
	<input type="hidden" name="endDate" value={endDate} />
</form>

<section
	class="rounded-lg border border-flapjack-ink/20 p-4"
	data-testid="analytics-subtab-panel-devices"
>
	<h3 class="mb-4 text-sm font-semibold text-flapjack-ink">Devices</h3>

	{#if isLoading && !hasLoaded}
		<div class="grid grid-cols-1 gap-4 md:grid-cols-3" data-testid="devices-loading-skeleton">
			{#each ['desktop', 'mobile', 'tablet'] as cardId (cardId)}
				<div class="animate-pulse rounded-lg border border-flapjack-ink/20 p-4">
					<div class="h-4 w-20 rounded bg-flapjack-ink/20"></div>
					<div class="mt-3 h-8 w-14 rounded bg-flapjack-ink/15"></div>
				</div>
			{/each}
		</div>
	{:else}
		{#if devicesError}
			<div
				class="mb-4 rounded-md border border-flapjack-rose/35 bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
			>
				{devicesError}
			</div>
		{/if}

		<div class="mb-6 grid grid-cols-1 gap-4 md:grid-cols-3">
			<div class="rounded-lg border border-flapjack-ink/20 p-4" data-testid="device-card-desktop">
				<p class="text-sm font-medium text-flapjack-ink/60">Desktop</p>
				<p class="mt-1 text-3xl font-semibold text-flapjack-ink">{formatNumber(devices.desktop)}</p>
			</div>
			<div class="rounded-lg border border-flapjack-ink/20 p-4" data-testid="device-card-mobile">
				<p class="text-sm font-medium text-flapjack-ink/60">Mobile</p>
				<p class="mt-1 text-3xl font-semibold text-flapjack-ink">{formatNumber(devices.mobile)}</p>
			</div>
			<div class="rounded-lg border border-flapjack-ink/20 p-4" data-testid="device-card-tablet">
				<p class="text-sm font-medium text-flapjack-ink/60">Tablet</p>
				<p class="mt-1 text-3xl font-semibold text-flapjack-ink">{formatNumber(devices.tablet)}</p>
			</div>
		</div>

		{#if allCountsZero}
			<div
				class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4 text-sm text-flapjack-ink/70"
			>
				No device analytics were recorded for this date range.
			</div>
		{:else}
			<div class="rounded-lg border border-flapjack-ink/20 p-4" data-testid="devices-bar-chart">
				<h4 class="mb-3 text-sm font-semibold text-flapjack-ink">Device Breakdown</h4>
				{#if browser}
					<div class="h-64">
						<BarChart
							data={chartData}
							x="device"
							xScale={scaleBand().padding(0.25)}
							series={[{ key: 'count', label: 'Count', color: 'var(--color-flapjack-rose)' }]}
						/>
					</div>
				{:else}
					<table class="w-full text-left text-sm">
						<thead
							class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
						>
							<tr>
								<th class="px-3 py-2">Device</th>
								<th class="px-3 py-2">Count</th>
							</tr>
						</thead>
						<tbody class="divide-y">
							{#each chartData as row (row.device)}
								<tr>
									<td class="px-3 py-2 text-flapjack-ink/80">{row.device}</td>
									<td class="px-3 py-2 text-flapjack-ink">{formatNumber(row.count)}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				{/if}
			</div>
		{/if}
	{/if}
</section>
