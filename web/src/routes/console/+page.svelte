<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { browser } from '$app/environment';
	import { BarChart } from 'layerchart';
	import { scaleBand } from 'd3-scale';
	import type {
		DailyUsageEntry,
		EstimatedBillResponse,
		Index,
		OnboardingStatus
	} from '$lib/api/types';
	import {
		formatCents,
		formatNumber,
		formatPeriod,
		indexStatusBadgeColor,
		statusLabel
	} from '$lib/format';

	let { data } = $props();

	type FreeTierProgress = {
		searches: { used: number; limit: number };
		records: { used: number; limit: number };
		storage_mb: { used: number; limit: number };
		indexes: { used: number; limit: number };
	};
	type FreeTierMetric = {
		label: string;
		slug: string;
		usage: { used: number; limit: number };
	};

	const usage = $derived(data.usage);
	const dailyUsage: DailyUsageEntry[] = $derived(data.dailyUsage);
	const currentMonth: string = $derived(data.month);
	const estimate: EstimatedBillResponse | null = $derived(data.estimate ?? null);
	const indexes: Index[] = $derived(data.indexes ?? []);
	const onboardingStatus: OnboardingStatus | null = $derived(data.onboardingStatus ?? null);
	const planContext = $derived(data.planContext);
	const freeTierProgress: FreeTierProgress | null = $derived(data.freeTierProgress ?? null);
	const onboardingCompleted = $derived(
		planContext?.onboarding_completed ?? onboardingStatus?.completed ?? false
	);
	const freeTierMetrics = $derived<FreeTierMetric[]>(
		freeTierProgress
			? [
					{ label: 'Searches', slug: 'searches', usage: freeTierProgress.searches },
					{ label: 'Records', slug: 'records', usage: freeTierProgress.records },
					{ label: 'Storage (MB)', slug: 'storage-mb', usage: freeTierProgress.storage_mb },
					{ label: 'Indexes', slug: 'indexes', usage: freeTierProgress.indexes }
				]
			: []
	);

	const indexStatusSummary = $derived(() => {
		const counts: Record<string, number> = {};
		for (const idx of indexes) {
			const status = idx.status.toLowerCase();
			counts[status] = (counts[status] ?? 0) + 1;
		}
		return counts;
	});

	const hasUsage = $derived(
		usage.total_search_requests > 0 ||
			usage.total_write_operations > 0 ||
			usage.avg_storage_gb > 0 ||
			usage.avg_document_count > 0
	);
	// Aggregate daily usage by date for the chart (sum across regions)
	const dailyTotals = $derived(
		Object.values(
			dailyUsage.reduce<
				Record<string, { date: string; search_requests: number; write_operations: number }>
			>((acc, entry) => {
				if (!acc[entry.date]) {
					acc[entry.date] = { date: entry.date, search_requests: 0, write_operations: 0 };
				}
				acc[entry.date].search_requests += entry.search_requests;
				acc[entry.date].write_operations += entry.write_operations;
				return acc;
			}, {})
		).sort((a, b) => a.date.localeCompare(b.date))
	);

	// Sort regions alphabetically
	const regionData = $derived(
		[...usage.by_region].sort((a, b) => a.region.localeCompare(b.region))
	);

	// Generate last 6 months for the selector
	function getMonthOptions(): { value: string; label: string }[] {
		const options: { value: string; label: string }[] = [];
		const now = new Date();
		for (let i = 0; i < 6; i++) {
			const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
			const value = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
			const label = d.toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
			options.push({ value, label });
		}
		return options;
	}

	const monthOptions = getMonthOptions();

	function formatGb(n: number): string {
		return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
	}

	function formatProgressValue(value: number): string {
		if (Number.isInteger(value)) {
			return formatNumber(value);
		}
		return formatGb(value);
	}

	function formatProgressPercent(used: number, limit: number): string {
		if (limit <= 0) {
			return '0%';
		}
		const percent = Math.min((used / limit) * 100, 100);
		return `${Math.round(percent)}%`;
	}

	function handleMonthChange(event: Event) {
		const target = event.target as HTMLSelectElement;
		// eslint-disable-next-line svelte/no-navigation-without-resolve -- query-only relative navigation
		goto(`?month=${target.value}`);
	}
</script>

<svelte:head>
	<title>Console — Flapjack Cloud</title>
</svelte:head>

	<div>
		<div class="mb-6 flex items-center justify-between">
			<h1 class="text-2xl font-bold text-[#1f1b18]">Console</h1>

			<label class="flex items-center gap-2 text-sm text-[#4b4640]">
				<span>Month</span>
				<select
					class="rounded border border-[#1f1b18]/20 bg-[#fff8ea] px-3 py-1.5 text-sm text-[#1f1b18] focus:border-[#b83f5f] focus:ring-1 focus:ring-[#b83f5f]"
					value={currentMonth}
					onchange={handleMonthChange}
				>
				{#each monthOptions as opt (opt.value)}
					<option value={opt.value}>{opt.label}</option>
				{/each}
			</select>
		</label>
	</div>

	<!-- Estimated bill — shown regardless of usage (minimum may apply) -->
	{#if estimate}
		<div
			class="mb-6 rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-6 shadow"
			data-testid="estimated-bill"
		>
			<div class="flex items-center justify-between">
				<h2 class="text-lg font-medium text-[#1f1b18]">
					Estimated Bill for {formatPeriod(estimate.month + '-01')}
				</h2>
				<p class="text-2xl font-bold text-[#1f1b18]" data-testid="estimated-bill-total">
					{formatCents(estimate.total_cents)}
				</p>
			</div>
			{#if estimate.minimum_applied}
				<p class="mt-1 text-sm text-[#4b4640]">Shared plan minimum applied ($5.00 per month)</p>
			{/if}
			{#if estimate.line_items.length > 0}
				<details class="mt-3">
					<summary class="cursor-pointer text-sm text-[#b83f5f] hover:text-[#8d2842]">
						View breakdown
					</summary>
					<table class="mt-2 w-full text-sm">
						<thead>
							<tr class="border-b border-[#1f1b18]/15 text-left text-[#4b4640]">
								<th class="pb-2 font-medium">Description</th>
								<th class="pb-2 font-medium">Amount</th>
							</tr>
						</thead>
						<tbody>
							{#each estimate.line_items as item (item.description)}
								<tr class="border-b border-[#1f1b18]/10">
									<td class="py-2 text-[#4b4640]">{item.description}</td>
									<td class="py-2 text-[#1f1b18]">{formatCents(item.amount_cents)}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</details>
			{/if}
		</div>
	{/if}

	{#if freeTierProgress}
		<section
			class="mb-6 rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-6 shadow"
			data-testid="free-tier-progress"
		>
			<h2 class="text-lg font-medium text-[#1f1b18]">Free Plan Usage</h2>
			<p class="mt-1 text-sm text-[#4b4640]">
				Track your usage against the included monthly limits.
			</p>
			<div class="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
				{#each freeTierMetrics as metric (metric.label)}
					<div
						class="rounded border border-[#1f1b18]/15 bg-[#fffdf6] p-3"
						data-testid={`free-tier-metric-${metric.slug}`}
					>
						<p class="text-sm font-medium text-[#1f1b18]">{metric.label}</p>
						<p class="mt-1 text-sm text-[#4b4640]">
							{formatProgressValue(metric.usage.used)} / {formatProgressValue(metric.usage.limit)}
						</p>
						<div class="mt-2 h-2 rounded bg-[#1f1b18]/10">
							<div
								class="h-2 rounded bg-[#b83f5f]"
								data-testid={`free-tier-metric-bar-${metric.slug}`}
								style={`width:${formatProgressPercent(metric.usage.used, metric.usage.limit)}`}
							></div>
						</div>
					</div>
				{/each}
			</div>
		</section>
	{/if}

	{#if freeTierProgress && freeTierProgress.indexes.used >= freeTierProgress.indexes.limit}
		<div
			data-testid="index-quota-warning"
			class="mb-6 rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-4 text-sm text-[#1f1b18]"
		>
			<p class="font-medium">
				You've reached your free plan index limit ({freeTierProgress.indexes.used} / {freeTierProgress
					.indexes.limit}).
			</p>
			<p class="mt-1">
				Delete an existing index or
				<a
					href={resolve('/console/billing')}
					class="font-medium text-[#b83f5f] underline hover:text-[#8d2842]">upgrade your plan</a
				>
				to create more.
			</p>
		</div>
	{/if}

	<div
		class="mb-6 rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-6 shadow"
		data-testid="indexes-card"
	>
		<div class="flex items-center justify-between">
			<h2 class="text-lg font-medium text-[#1f1b18]">Indexes</h2>
			{#if indexes.length > 0}
				<a
					href={resolve('/console/indexes')}
					class="text-sm font-medium text-[#b83f5f] hover:text-[#8d2842]">Manage indexes</a
				>
			{/if}
		</div>
		{#if indexes.length === 0}
			<p class="mt-2 text-sm text-[#4b4640]">No indexes yet</p>
			<a
				href={resolve('/console/onboarding')}
				class="mt-3 inline-block text-sm font-medium text-[#b83f5f] hover:text-[#8d2842]"
				>Create your first index</a
			>
		{:else}
			<p class="mt-1 text-3xl font-bold text-[#1f1b18]">
				{indexes.length}
				{#if freeTierProgress}
					<span class="ml-2 text-lg font-medium text-[#4b4640]"
						>/ {freeTierProgress.indexes.limit}</span
					>
				{/if}
			</p>
			<div class="mt-3 flex flex-wrap gap-2">
				{#each Object.entries(indexStatusSummary()) as [status, count] (status)}
					<span
						class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium {indexStatusBadgeColor(
							status
						)}"
					>
						{count}
						{statusLabel(status)}
					</span>
				{/each}
			</div>
		{/if}
	</div>

	{#if onboardingStatus && !onboardingCompleted}
		<div
			class="mb-6 rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-4"
			data-testid="onboarding-banner"
		>
			<div class="flex items-center justify-between">
				<div>
					<p class="font-medium text-[#1f1b18]">Complete your setup</p>
					<p class="mt-1 text-sm text-[#4b4640]">{onboardingStatus.suggested_next_step}</p>
					{#if planContext?.billing_plan === 'free'}
						<p class="mt-1 text-sm text-[#4b4640]">No credit card required on the Free plan.</p>
					{/if}
				</div>
				<a
					href={resolve('/console/onboarding')}
					class="rounded-md border-2 border-[#1f1b18] bg-[#ffb3c7] px-4 py-2 text-sm font-medium text-[#1f1b18] hover:bg-[#ffc3d2]"
					>Continue setup</a
				>
			</div>
		</div>
	{/if}

	{#if hasUsage}
		<!-- Stat cards -->
		<div class="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4" data-testid="stat-cards">
			<div class="rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-6 shadow">
				<p class="text-sm font-medium text-[#4b4640]">Search Requests</p>
				<p class="mt-1 text-2xl font-semibold text-[#1f1b18]">
					{formatNumber(usage.total_search_requests)}
				</p>
			</div>
			<div class="rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-6 shadow">
				<p class="text-sm font-medium text-[#4b4640]">Write Operations</p>
				<p class="mt-1 text-2xl font-semibold text-[#1f1b18]">
					{formatNumber(usage.total_write_operations)}
				</p>
			</div>
			<div class="rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-6 shadow">
				<p class="text-sm font-medium text-[#4b4640]">Storage (GB)</p>
				<p class="mt-1 text-2xl font-semibold text-[#1f1b18]">{formatGb(usage.avg_storage_gb)}</p>
			</div>
			<div class="rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-6 shadow">
				<p class="text-sm font-medium text-[#4b4640]">Documents</p>
				<p class="mt-1 text-2xl font-semibold text-[#1f1b18]">
					{formatNumber(usage.avg_document_count)}
				</p>
			</div>
		</div>

		<!-- Daily usage chart -->
		{#if dailyTotals.length > 0}
			<div
				class="mb-6 rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-6 shadow"
				data-testid="usage-chart"
			>
				<h2 class="mb-4 text-lg font-medium text-[#1f1b18]">Daily Usage</h2>
				{#if browser}
					<div class="h-64">
						<BarChart
							data={dailyTotals}
							x="date"
							xScale={scaleBand().padding(0.25)}
							series={[
								{ key: 'search_requests', label: 'Search Requests', color: '#b83f5f' },
								{
									key: 'write_operations',
									label: 'Write Operations',
									color: '#7f4d21'
								}
							]}
							seriesLayout="group"
							legend
						/>
					</div>
				{:else}
					<div class="overflow-x-auto">
						<table class="w-full text-sm">
							<thead>
								<tr class="border-b border-[#1f1b18]/15 text-left text-[#4b4640]">
									<th class="pb-2 font-medium">Date</th>
									<th class="pb-2 font-medium">Search Requests</th>
									<th class="pb-2 font-medium">Write Operations</th>
								</tr>
							</thead>
							<tbody>
								{#each dailyTotals as day (day.date)}
									<tr class="border-b border-[#1f1b18]/10">
										<td class="py-2 text-[#4b4640]">{day.date}</td>
										<td class="py-2 text-[#1f1b18]">{formatNumber(day.search_requests)}</td>
										<td class="py-2 text-[#1f1b18]">{formatNumber(day.write_operations)}</td>
									</tr>
								{/each}
							</tbody>
						</table>
					</div>
				{/if}
			</div>
		{/if}

		<!-- Region breakdown table -->
		<div
			class="rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-6 shadow"
			data-testid="region-breakdown"
		>
			<h2 class="mb-4 text-lg font-medium text-[#1f1b18]">Region Breakdown</h2>
			<table class="w-full text-sm">
				<thead>
					<tr class="border-b border-[#1f1b18]/15 text-left text-[#4b4640]">
						<th class="pb-2 font-medium">Region</th>
						<th class="pb-2 font-medium">Search Requests</th>
						<th class="pb-2 font-medium">Write Operations</th>
						<th class="pb-2 font-medium">Storage (GB)</th>
						<th class="pb-2 font-medium">Documents</th>
					</tr>
				</thead>
				<tbody>
					{#each regionData as region (region.region)}
						<tr class="border-b border-[#1f1b18]/10">
							<td class="py-2 font-medium text-[#4b4640]">{region.region}</td>
							<td class="py-2 text-[#1f1b18]">{formatNumber(region.search_requests)}</td>
							<td class="py-2 text-[#1f1b18]">{formatNumber(region.write_operations)}</td>
							<td class="py-2 text-[#1f1b18]">{formatGb(region.avg_storage_gb)}</td>
							<td class="py-2 text-[#1f1b18]">{formatNumber(region.avg_document_count)}</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{:else}
		<div class="rounded-lg border-2 border-[#1f1b18]/15 bg-[#fff8ea] p-12 text-center shadow">
			<p class="text-[#4b4640]">No usage data for this period.</p>
		</div>
	{/if}
</div>
