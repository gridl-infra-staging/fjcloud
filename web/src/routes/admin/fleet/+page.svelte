<script lang="ts">
	import { resolve } from '$app/paths';
	import { invalidate } from '$app/navigation';
	import { enhance } from '$app/forms';
	import { onMount } from 'svelte';
	import { SvelteMap, SvelteSet } from 'svelte/reactivity';
	import { adminBadgeColor, formatBytes, formatDate } from '$lib/format';
	import { aggregateDiskUtilPercent, capacityDimensions, utilPercent } from '$lib/vm-capacity';
	import type {
		AdminReplicaEntry,
		VmHostMetricsResponse,
		VmInventoryItem
	} from '$lib/admin-client';

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
	const fleetAvailable = $derived(data.fleetAvailable ?? true);
	const vms = $derived(data.vms);
	const vmCapacityAvailable = $derived(data.vmCapacityAvailable);
	// Replica placement is a frontend join over the canonical /admin/replicas
	// data. `replicaPlacementAvailable` defaults to true for older test payloads
	// that predate the replicas fetch; a false value means the fetch failed and
	// the UI must not read that as an empty replica set.
	const replicas = $derived((data.replicas ?? []) as AdminReplicaEntry[]);
	const replicaPlacementAvailable = $derived(data.replicaPlacementAvailable ?? true);
	const hostMetricsByVmId = $derived(
		(data.hostMetricsByVmId ?? {}) as Record<string, VmHostMetricsResponse | null>
	);

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

	const totalDeployments = $derived(fleet.length);
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
	const capacityDimensionKeys = $derived.by(() => {
		const keys = new SvelteSet<string>();
		for (const vm of vms) {
			for (const dimension of capacityDimensions(vm.capacity, vm.current_load)) {
				keys.add(dimension.key);
			}
		}
		return [...keys].sort();
	});
	const regionRollups = $derived.by(() => {
		const byRegion = new SvelteMap<string, VmInventoryItem[]>();
		for (const vm of vms) {
			const regionVms = byRegion.get(vm.region) ?? [];
			regionVms.push(vm);
			byRegion.set(vm.region, regionVms);
		}

		return [...byRegion.entries()]
			.sort(([leftRegion], [rightRegion]) => leftRegion.localeCompare(rightRegion))
			.map(([region, regionVms]) => ({
				region,
				vmCount: regionVms.length,
				diskUtilPercent: aggregateDiskUtilPercent(regionVms)
			}));
	});

	// Display-only rollup of replica roles per VM. Formats facts already owned by
	// AdminReplicaEntry; it does not re-derive backend filtering or replica status.
	type ReplicaPlacement = {
		primaryCount: number;
		replicaCount: number;
		primaryReplicaRegions: string[];
		hostedReplicaRegions: string[];
	};

	function emptyReplicaPlacement(): ReplicaPlacement {
		return {
			primaryCount: 0,
			replicaCount: 0,
			primaryReplicaRegions: [],
			hostedReplicaRegions: []
		};
	}

	const replicaPlacementByVm = $derived.by(() => {
		const byVm = new SvelteMap<string, ReplicaPlacement>();
		const placementFor = (vmId: string): ReplicaPlacement => {
			const existing = byVm.get(vmId);
			if (existing) return existing;
			const created = emptyReplicaPlacement();
			byVm.set(vmId, created);
			return created;
		};
		for (const replica of replicas) {
			const primary = placementFor(replica.primary_vm_id);
			primary.primaryCount += 1;
			primary.primaryReplicaRegions.push(replica.replica_region);

			const host = placementFor(replica.replica_vm_id);
			host.replicaCount += 1;
			host.hostedReplicaRegions.push(replica.replica_region);
		}
		return byVm;
	});

	function replicaPlacementFor(vmId: string): ReplicaPlacement {
		return replicaPlacementByVm.get(vmId) ?? emptyReplicaPlacement();
	}

	function regionLabel(regions: string[]): string {
		return [...new Set(regions)].sort().join(', ');
	}

	function shortId(id: string): string {
		return id.split('-')[0];
	}

	function optionLabel(value: string): string {
		if (value === 'all') return 'All';
		if (FILTER_LABEL_OVERRIDES[value]) return FILTER_LABEL_OVERRIDES[value];
		return value.replaceAll('_', ' ').replace(/\b\w/g, (char) => char.toUpperCase());
	}

	function utilizationLabel(vm: VmInventoryItem, key: string): string {
		const dimension = capacityDimensions(vm.capacity, vm.current_load).find(
			(dim) => dim.key === key
		);
		if (!dimension) return 'Unavailable';
		return `${utilPercent(dimension.used, dimension.total)}%`;
	}

	function hostMetricsFor(vmId: string): VmHostMetricsResponse | null {
		return hostMetricsByVmId[vmId] ?? null;
	}

	function hostDiskLabel(metrics: VmHostMetricsResponse | null): string {
		if (!metrics) return 'No host data';
		if (
			metrics.disk_used_bytes === null ||
			metrics.disk_total_bytes === null ||
			metrics.disk_total_bytes <= 0
		) {
			return '—';
		}
		return `${utilPercent(metrics.disk_used_bytes, metrics.disk_total_bytes)}%`;
	}

	function hostCpuLabel(metrics: VmHostMetricsResponse | null): string {
		if (!metrics) return 'No host data';
		return `${metrics.cpu_pct}%`;
	}

	function hostRamLabel(metrics: VmHostMetricsResponse | null): string {
		if (!metrics) return 'No host data';
		if (metrics.mem_total_bytes <= 0) return '—';
		return `${utilPercent(metrics.mem_used_bytes, metrics.mem_total_bytes)}%`;
	}

	function hostNetworkLabel(metrics: VmHostMetricsResponse | null): string {
		if (!metrics) return 'No host data';
		return `RX total ${formatBytes(metrics.net_rx_bytes)} / TX total ${formatBytes(metrics.net_tx_bytes)}`;
	}

	function vmCountLabel(count: number): string {
		return `${count} ${count === 1 ? 'VM' : 'VMs'}`;
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
	{#if !vmCapacityAvailable}
		<div
			class="rounded-lg border border-amber-700/40 bg-amber-950/30 px-4 py-3 text-sm text-amber-300"
			role="alert"
			data-testid="vm-capacity-unavailable"
		>
			VM capacity unavailable. Deployment data may still be available below.
		</div>
	{:else if vms.length > 0}
		<div class="space-y-3">
			<h3 class="text-lg font-medium text-white">VM Capacity</h3>
			<p class="text-xs text-slate-500">
				Underlying Flapjack processes. Kill a VM to trigger health monitor detection and regional
				failover.
			</p>
			<div class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
				{#each regionRollups as rollup (rollup.region)}
					<div
						class="rounded-lg border border-slate-700 bg-slate-800/60 p-4"
						data-testid={`region-rollup-${rollup.region}`}
					>
						<p class="text-sm font-medium text-white">{rollup.region}</p>
						<p class="mt-1 text-xs uppercase tracking-wide text-slate-400">VM count</p>
						<p class="text-lg font-semibold text-slate-100">{vmCountLabel(rollup.vmCount)}</p>
						<p class="mt-3 text-xs uppercase tracking-wide text-slate-400">
							Aggregate disk utilization
						</p>
						<p class="text-lg font-semibold text-slate-100">
							{rollup.diskUtilPercent === null ? 'Unavailable' : `${rollup.diskUtilPercent}%`}
						</p>
					</div>
				{/each}
			</div>
			<div
				class="overflow-x-auto rounded-lg border border-slate-700"
				data-testid="capacity-table-scroll"
			>
				<table class="w-full text-left text-sm">
					<thead
						class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
					>
						<tr>
							<th class="px-4 py-3">Hostname</th>
							<th class="px-4 py-3">Region</th>
							<th class="px-4 py-3">Provider</th>
							<th class="px-4 py-3">Status</th>
							<th class="px-4 py-3">Health</th>
							{#each capacityDimensionKeys as dimensionKey (dimensionKey)}
								<th class="px-4 py-3">{dimensionKey} (proxy)</th>
							{/each}
							<th class="px-4 py-3">Disk (host)</th>
							<th class="px-4 py-3">CPU (host)</th>
							<th class="px-4 py-3">RAM (host)</th>
							<th class="px-4 py-3">Network RX/TX totals (host)</th>
							<th class="px-4 py-3">Replica placement</th>
							<th class="px-4 py-3">Tenants</th>
							<th class="px-4 py-3">Indexes</th>
							<th class="px-4 py-3">Flapjack URL</th>
							<th class="px-4 py-3">Updated</th>
							<th class="px-4 py-3">Actions</th>
						</tr>
					</thead>
					<tbody data-testid="capacity-table-body" class="divide-y divide-slate-700/50">
						{#each vms as vm (vm.id)}
							<tr class="transition hover:bg-slate-800/40" data-testid={`capacity-row-${vm.id}`}>
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
								<td class="px-4 py-3" data-testid={`vm-health-${vm.id}`}>
									<span
										class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
											vm.health
										)}"
									>
										{vm.health}
									</span>
								</td>
								{#each capacityDimensionKeys as dimensionKey (dimensionKey)}
									<td
										class="px-4 py-3 text-slate-300"
										data-testid={`capacity-util-${vm.id}-${dimensionKey}`}
									>
										{utilizationLabel(vm, dimensionKey)}
									</td>
								{/each}
								<td class="px-4 py-3 text-slate-300" data-testid={`host-disk-${vm.id}`}>
									{hostDiskLabel(hostMetricsFor(vm.id))}
								</td>
								<td class="px-4 py-3 text-slate-300" data-testid={`host-cpu-${vm.id}`}>
									{hostCpuLabel(hostMetricsFor(vm.id))}
								</td>
								<td class="px-4 py-3 text-slate-300" data-testid={`host-ram-${vm.id}`}>
									{hostRamLabel(hostMetricsFor(vm.id))}
								</td>
								<td class="px-4 py-3 text-slate-300" data-testid={`host-net-${vm.id}`}>
									{hostNetworkLabel(hostMetricsFor(vm.id))}
								</td>
								<td
									class="px-4 py-3 text-xs text-slate-300"
									data-testid={`capacity-replicas-${vm.id}`}
								>
									{#if !replicaPlacementAvailable}
										Replica placement unavailable
									{:else}
										{@const placement = replicaPlacementFor(vm.id)}
										{#if placement.primaryCount === 0 && placement.replicaCount === 0}
											No replicas
										{:else}
											<div>Primary: {placement.primaryCount}</div>
											<div>Replica: {placement.replicaCount}</div>
											{#if placement.primaryCount > 0}
												<div>Replica regions: {regionLabel(placement.primaryReplicaRegions)}</div>
											{/if}
											{#if placement.replicaCount > 0}
												<div>Hosts replica: {regionLabel(placement.hostedReplicaRegions)}</div>
											{/if}
										{/if}
									{/if}
								</td>
								<td class="px-4 py-3 text-slate-300" data-testid={`tenant-count-${vm.id}`}>
									{vm.tenant_count}
								</td>
								<td class="px-4 py-3 text-slate-300" data-testid={`index-count-${vm.id}`}>
									{vm.index_count}
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
												data-testid={`kill-vm-${vm.id}`}
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
	{#if !fleetAvailable}
		<div
			class="rounded-lg border border-amber-700/40 bg-amber-950/30 px-4 py-3 text-sm text-amber-300"
			role="alert"
			data-testid="fleet-unavailable"
		>
			Deployment data unavailable. VM capacity data may still be available above.
		</div>
	{:else}
		<div class="grid grid-cols-2 gap-4 md:grid-cols-3 lg:grid-cols-6">
			<div class="rounded-lg border border-slate-700 bg-slate-800/60 p-4">
				<p class="text-xs font-medium uppercase tracking-wide text-slate-400">Total Deployments</p>
				<p class="mt-1 text-2xl font-bold text-white" data-testid="total-deployments">
					{totalDeployments}
				</p>
			</div>
			{#each STATUS_SUMMARY_DEFINITIONS as statusDef (statusDef.value)}
				<div class={`rounded-lg border bg-slate-800/60 p-4 ${statusDef.borderClass}`}>
					<p class={`text-xs font-medium uppercase tracking-wide ${statusDef.labelClass}`}>
						{statusDef.label}
					</p>
					<p
						class={`mt-1 text-2xl font-bold ${statusDef.valueClass}`}
						data-testid={statusDef.testId}
					>
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
			<label for="status-filter" class="text-sm font-medium text-slate-300">Filter by status:</label
			>
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
			<div
				class="overflow-x-auto rounded-lg border border-slate-700"
				data-testid="deployment-table-scroll"
			>
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
							<tr
								class="transition hover:bg-slate-800/40"
								data-testid={`fleet-row-${deployment.id}`}
							>
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
	{/if}
</div>
