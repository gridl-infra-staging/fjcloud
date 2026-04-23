<script lang="ts">
	import { resolve } from '$app/paths';
	import { invalidate } from '$app/navigation';
	import { enhance } from '$app/forms';
	import { onMount } from 'svelte';
	import { adminBadgeColor, formatDate } from '$lib/format';

	let { data, form } = $props();

	let statusFilter = $state('all');
	let providerFilter = $state('all');
	// Auto-refresh interval in ms. 5s gives near-real-time health visibility
	// for the HA demo without hammering the API.
	let autoRefresh = $state(true);
	// Tracks which VM is being killed so we can show a spinner/disabled state.
	let killingVmId = $state<string | null>(null);
	// Error from the server action, shown as a banner.
	const killError = $derived(form?.error ?? null);

	const fleet = $derived(data.fleet);
	const vms = $derived(data.vms);

	const STATUS_SUMMARY_DEFINITIONS = [
		{
			value: 'running',
			label: 'Running',
			testId: 'running-count',
			borderClass: 'border-green-700/40',
			labelClass: 'text-green-400',
			valueClass: 'text-green-300'
		},
		{
			value: 'provisioning',
			label: 'Provisioning',
			testId: 'provisioning-count',
			borderClass: 'border-blue-700/40',
			labelClass: 'text-blue-400',
			valueClass: 'text-blue-300'
		},
		{
			value: 'stopped',
			label: 'Stopped',
			testId: 'stopped-count',
			borderClass: 'border-yellow-700/40',
			labelClass: 'text-yellow-400',
			valueClass: 'text-yellow-300'
		},
		{
			value: 'failed',
			label: 'Failed',
			testId: 'failed-count',
			borderClass: 'border-red-700/40',
			labelClass: 'text-red-400',
			valueClass: 'text-red-300'
		}
	] as const;

	const totalVms = $derived(fleet.length);
	const statusSummaryCounts = $derived(
		Object.fromEntries(
			STATUS_SUMMARY_DEFINITIONS.map((statusDef) => [
				statusDef.value,
				fleet.filter((deployment) => deployment.status === statusDef.value).length
			])
		) as Record<string, number>
	);
	const unhealthyCount = $derived(fleet.filter((d) => d.health_status === 'unhealthy').length);
	const statusFilterOptions = $derived([
		'all',
		...new Set([
			...STATUS_SUMMARY_DEFINITIONS.map((statusDef) => statusDef.value),
			...fleet.map((d) => d.status)
		])
	]);
	const providerFilterOptions = $derived(['all', ...new Set(fleet.map((d) => d.vm_provider))]);
	const FILTER_LABEL_OVERRIDES: Record<string, string> = {
		aws: 'AWS',
		gcp: 'GCP',
		oci: 'OCI'
	};

	const filteredFleet = $derived(
		fleet.filter(
			(d) =>
				(statusFilter === 'all' || d.status === statusFilter) &&
				(providerFilter === 'all' || d.vm_provider === providerFilter)
		)
	);

	function shortId(id: string): string {
		return id.split('-')[0];
	}

	function optionLabel(value: string): string {
		if (value === 'all') return 'All';
		if (FILTER_LABEL_OVERRIDES[value]) return FILTER_LABEL_OVERRIDES[value];
		return value.replaceAll('_', ' ').replace(/\b\w/g, (char) => char.toUpperCase());
	}

	// Returns true if the URL is a localhost address (safe to kill).
	// Matches the Rust is_localhost_url logic for UI consistency.
	function isLocalUrl(url: string): boolean {
		try {
			const parsed = new URL(url);
			const host = parsed.hostname;
			return host === '127.0.0.1' || host === 'localhost' || host === '::1';
		} catch {
			return false;
		}
	}

	// Auto-refresh: poll fleet + VM data every 5s when enabled.
	// This lets you watch health status change in real-time after killing a VM.
	onMount(() => {
		const timer = setInterval(() => {
			if (autoRefresh) {
				invalidate('admin:fleet');
			}
		}, 5000);

		return () => clearInterval(timer);
	});
</script>

<svelte:head>
	<title>Fleet - Admin Panel</title>
</svelte:head>

<div class="space-y-6">
	<div class="flex items-center justify-between">
		<h2 class="text-xl font-semibold text-white">Fleet Overview</h2>
		<!-- Auto-refresh toggle for HA demo observability -->
		<label class="flex items-center gap-2 text-sm text-slate-400">
			<input
				type="checkbox"
				bind:checked={autoRefresh}
				class="rounded border-slate-600 bg-slate-800 text-violet-500 focus:ring-violet-500"
				data-testid="auto-refresh-toggle"
			/>
			Auto-refresh (5s)
		</label>
	</div>

	{#if killError}
		<div
			class="rounded-lg border border-red-700/40 bg-red-900/20 p-3 text-sm text-red-300"
			data-testid="kill-error"
		>
			{killError}
		</div>
	{/if}

	<!-- VM Infrastructure section — shows the underlying VMs from vm_inventory.
	     In local dev, these are the Flapjack processes with localhost URLs.
	     The Kill button sends SIGTERM to the process, letting you demo HA failover. -->
	{#if vms.length > 0}
		<div class="space-y-3">
			<h3 class="text-lg font-medium text-white">VM Infrastructure</h3>
			<p class="text-xs text-slate-500">
				Underlying Flapjack processes. Kill a VM to trigger health monitor detection and regional
				failover.
			</p>
			<div class="overflow-x-auto rounded-lg border border-slate-700">
				<table class="w-full text-left text-sm">
					<thead
						class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
					>
						<tr>
							<th class="px-4 py-3">Hostname</th>
							<th class="px-4 py-3">Region</th>
							<th class="px-4 py-3">Provider</th>
							<th class="px-4 py-3">Status</th>
							<th class="px-4 py-3">Flapjack URL</th>
							<th class="px-4 py-3">Updated</th>
							<th class="px-4 py-3">Actions</th>
						</tr>
					</thead>
					<tbody data-testid="vm-table-body" class="divide-y divide-slate-700/50">
						{#each vms as vm (vm.id)}
							<tr class="transition hover:bg-slate-800/40">
								<td class="px-4 py-3 font-mono text-sm text-violet-300">
									<a
										href={resolve(`/admin/fleet/${vm.id}`)}
										class="hover:text-violet-200 hover:underline"
									>
										{vm.hostname}
									</a>
								</td>
								<td class="px-4 py-3 text-slate-300">{vm.region}</td>
								<td class="px-4 py-3 text-slate-300">{vm.provider}</td>
								<td class="px-4 py-3">
									<span
										class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
											vm.status
										)}"
									>
										{vm.status}
									</span>
								</td>
								<td class="px-4 py-3 font-mono text-xs text-slate-400">
									{vm.flapjack_url}
								</td>
								<td class="px-4 py-3 text-xs text-slate-400">
									{formatDate(vm.updated_at)}
								</td>
								<td class="px-4 py-3">
									{#if isLocalUrl(vm.flapjack_url)}
										<!-- Form action keeps ADMIN_KEY server-side.
										     enhance() prevents full page reload. -->
										<form
											method="POST"
											action="?/killVm"
											use:enhance={() => {
												killingVmId = vm.id;
												return async ({ update }) => {
													killingVmId = null;
													// Rerun load to refresh fleet + VM data
													await update();
													await invalidate('admin:fleet');
												};
											}}
										>
											<input type="hidden" name="vmId" value={vm.id} />
											<button
												type="submit"
												disabled={killingVmId === vm.id}
												class="rounded-md bg-red-600/20 px-3 py-1 text-xs font-medium text-red-300 hover:bg-red-600/40 disabled:opacity-50 disabled:cursor-not-allowed transition"
												data-testid={`kill-vm-${vm.region}`}
											>
												{killingVmId === vm.id ? 'Killing...' : 'Kill'}
											</button>
										</form>
									{:else}
										<span class="text-xs text-slate-600">remote</span>
									{/if}
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		</div>
	{/if}

	<!-- Deployment summary cards (existing) -->
	<h3 class="text-lg font-medium text-white">Deployments</h3>
	<div class="grid grid-cols-2 gap-4 md:grid-cols-3 lg:grid-cols-6">
		<div class="rounded-lg border border-slate-700 bg-slate-800/60 p-4">
			<p class="text-xs font-medium uppercase tracking-wide text-slate-400">Total VMs</p>
			<p class="mt-1 text-2xl font-bold text-white" data-testid="total-vms">{totalVms}</p>
		</div>
		{#each STATUS_SUMMARY_DEFINITIONS as statusDef (statusDef.value)}
			<div class={`rounded-lg border bg-slate-800/60 p-4 ${statusDef.borderClass}`}>
				<p class={`text-xs font-medium uppercase tracking-wide ${statusDef.labelClass}`}>
					{statusDef.label}
				</p>
				<p class={`mt-1 text-2xl font-bold ${statusDef.valueClass}`} data-testid={statusDef.testId}>
					{statusSummaryCounts[statusDef.value]}
				</p>
			</div>
		{/each}
		<div class="rounded-lg border border-red-700/40 bg-slate-800/60 p-4">
			<p class="text-xs font-medium uppercase tracking-wide text-red-400">Unhealthy</p>
			<p class="mt-1 text-2xl font-bold text-red-300" data-testid="unhealthy-count">
				{unhealthyCount}
			</p>
		</div>
	</div>

	<!-- Filters -->
	<div class="flex items-center gap-4">
		<label for="status-filter" class="text-sm font-medium text-slate-300">Filter by status:</label>
		<select
			id="status-filter"
			data-testid="status-filter"
			bind:value={statusFilter}
			class="rounded-md border border-slate-600 bg-slate-800 px-3 py-1.5 text-sm text-slate-200 focus:border-violet-400 focus:outline-none"
		>
			{#each statusFilterOptions as statusValue (statusValue)}
				<option value={statusValue}>{optionLabel(statusValue)}</option>
			{/each}
		</select>

		<label for="provider-filter" class="text-sm font-medium text-slate-300">Provider:</label>
		<select
			id="provider-filter"
			data-testid="provider-filter"
			bind:value={providerFilter}
			class="rounded-md border border-slate-600 bg-slate-800 px-3 py-1.5 text-sm text-slate-200 focus:border-violet-400 focus:outline-none"
		>
			{#each providerFilterOptions as providerValue (providerValue)}
				<option value={providerValue}>{optionLabel(providerValue)}</option>
			{/each}
		</select>
	</div>

	<!-- Deployment table (existing) -->
	{#if fleet.length === 0}
		<div class="rounded-lg border border-slate-700 bg-slate-800/40 p-8 text-center">
			<p class="text-slate-400">No deployments found.</p>
		</div>
	{:else}
		<div class="overflow-x-auto rounded-lg border border-slate-700">
			<table class="w-full text-left text-sm">
				<thead
					class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
				>
					<tr>
						<th class="px-4 py-3">ID</th>
						<th class="px-4 py-3">Provider</th>
						<th class="px-4 py-3">Region</th>
						<th class="px-4 py-3">Status</th>
						<th class="px-4 py-3">Health</th>
						<th class="px-4 py-3">Customer</th>
						<th class="px-4 py-3">URL</th>
						<th class="px-4 py-3">Last Check</th>
						<th class="px-4 py-3">Created</th>
					</tr>
				</thead>
				<tbody data-testid="fleet-table-body" class="divide-y divide-slate-700/50">
					{#each filteredFleet as deployment (deployment.id)}
						<tr class="transition hover:bg-slate-800/40">
							<td class="px-4 py-3 font-mono text-sm text-violet-300">
								{shortId(deployment.id)}
							</td>
							<td class="px-4 py-3 text-slate-300">{deployment.vm_provider}</td>
							<td class="px-4 py-3 text-slate-300">{deployment.region}</td>
							<td class="px-4 py-3">
								<span
									class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
										deployment.status
									)}"
								>
									{deployment.status}
								</span>
							</td>
							<td class="px-4 py-3">
								<span
									class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
										deployment.health_status
									)}"
								>
									{deployment.health_status}
								</span>
							</td>
							<td class="px-4 py-3 font-mono text-xs text-slate-400">
								{shortId(deployment.customer_id)}
							</td>
							<td class="px-4 py-3 text-xs text-slate-400">
								{deployment.flapjack_url ?? '—'}
							</td>
							<td class="px-4 py-3 text-xs text-slate-400">
								{formatDate(deployment.last_health_check_at)}
							</td>
							<td class="px-4 py-3 text-xs text-slate-400">
								{formatDate(deployment.created_at)}
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>
