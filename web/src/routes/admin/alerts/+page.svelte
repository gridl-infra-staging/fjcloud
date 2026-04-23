<script lang="ts">
	import { invalidate } from '$app/navigation';
	import type { AdminAlertRecord, AlertSeverity } from '$lib/admin-client';
	import { onMount } from 'svelte';
	import { SvelteSet } from 'svelte/reactivity';

	type SeverityFilter = 'all' | AlertSeverity;

	let { data } = $props();

	function initialSelectedSeverity(): SeverityFilter {
		return (data.selectedSeverity ?? 'all') as SeverityFilter;
	}

	let selectedSeverity = $state<SeverityFilter>(initialSelectedSeverity());
	let expandedMetadataIds = new SvelteSet<string>();

	const alerts = $derived(data.alerts as AdminAlertRecord[]);
	const filteredAlerts = $derived(
		selectedSeverity === 'all'
			? alerts
			: alerts.filter((alert) => alert.severity === selectedSeverity)
	);

	function formatTimestamp(isoTimestamp: string): string {
		return new Date(isoTimestamp).toLocaleString();
	}

	function severityBadgeClass(severity: AlertSeverity): string {
		switch (severity) {
			case 'critical':
				return 'border-red-600/60 bg-red-500/20 text-red-200';
			case 'warning':
				return 'border-amber-600/60 bg-amber-500/20 text-amber-200';
			default:
				return 'border-emerald-600/60 bg-emerald-500/20 text-emerald-200';
		}
	}

	function toggleMetadata(alertId: string): void {
		if (expandedMetadataIds.has(alertId)) {
			expandedMetadataIds.delete(alertId);
		} else {
			expandedMetadataIds.add(alertId);
		}
	}

	function metadataEntries(metadata: Record<string, unknown>): [string, string][] {
		return Object.entries(metadata ?? {}).map(([key, value]) => [key, String(value)]);
	}

	onMount(() => {
		const refreshTimer = setInterval(() => {
			void invalidate('admin:alerts');
		}, 15_000);

		return () => clearInterval(refreshTimer);
	});
</script>

<svelte:head>
	<title>Alerts - Admin Panel</title>
</svelte:head>

<div class="space-y-6">
	<div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
		<h2 class="text-xl font-semibold text-white">Alerts</h2>
		<label class="inline-flex items-center gap-2 text-sm text-slate-300" for="severity-filter">
			Severity
			<select
				id="severity-filter"
				data-testid="severity-filter"
				bind:value={selectedSeverity}
				class="rounded-md border border-slate-700 bg-slate-900 px-3 py-1.5 text-sm text-slate-100"
			>
				<option value="all">All</option>
				<option value="critical">Critical</option>
				<option value="warning">Warning</option>
				<option value="info">Info</option>
			</select>
		</label>
	</div>

	{#if filteredAlerts.length === 0}
		<div class="rounded-lg border border-slate-700 bg-slate-800/60 p-5 text-sm text-slate-300">
			No alerts found.
		</div>
	{:else}
		<div class="overflow-x-auto rounded-lg border border-slate-700">
			<table class="w-full text-left text-sm">
				<thead class="border-b border-slate-700 bg-slate-900/80 text-xs uppercase tracking-wide text-slate-400">
					<tr>
						<th class="px-4 py-3">Timestamp</th>
						<th class="px-4 py-3">Severity</th>
						<th class="px-4 py-3">Title</th>
						<th class="px-4 py-3">Message</th>
						<th class="px-4 py-3">Metadata</th>
					</tr>
				</thead>
				<tbody data-testid="alerts-table-body" class="divide-y divide-slate-800">
					{#each filteredAlerts as alert (alert.id)}
						<tr class="align-top">
							<td class="px-4 py-3 text-xs text-slate-400">{formatTimestamp(alert.created_at)}</td>
							<td class="px-4 py-3">
								<span
									class={`inline-flex rounded-full border px-2 py-0.5 text-xs font-medium ${severityBadgeClass(alert.severity)}`}
								>
									{alert.severity}
								</span>
							</td>
							<td class="px-4 py-3 font-medium text-slate-100">{alert.title}</td>
							<td class="px-4 py-3 text-slate-300">{alert.message}</td>
							<td class="px-4 py-3">
								{#if metadataEntries(alert.metadata).length === 0}
									<span class="text-xs text-slate-500">None</span>
								{:else}
									<button
										type="button"
										onclick={() => toggleMetadata(alert.id)}
										class="text-xs font-medium text-violet-300 hover:text-violet-200"
									>
										{expandedMetadataIds.has(alert.id) ? 'Hide metadata' : 'View metadata'}
									</button>
									{#if expandedMetadataIds.has(alert.id)}
										<div class="mt-2 space-y-1 rounded-md border border-slate-700 bg-slate-900 p-2 text-xs">
											{#each metadataEntries(alert.metadata) as [key, value] (key)}
												<p class="text-slate-300">
													<span class="font-semibold text-slate-100">{key}:</span>
													{value}
												</p>
											{/each}
										</div>
									{/if}
								{/if}
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>
