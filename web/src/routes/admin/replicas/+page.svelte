<script lang="ts">
	import { adminBadgeColor, formatDate } from '$lib/format';

	let { data } = $props();

	let statusFilter = $state('all');

	const replicas = $derived(data.replicas);

	const totalReplicas = $derived(replicas.length);
	const activeCount = $derived(replicas.filter((r) => r.status === 'active').length);
	const syncingCount = $derived(
		replicas.filter((r) => r.status === 'syncing' || r.status === 'replicating').length
	);
	const failedCount = $derived(replicas.filter((r) => r.status === 'failed').length);

	function matchesStatusFilter(status: string, filter: string): boolean {
		if (filter === 'all') return true;
		if (filter === 'syncing') return status === 'syncing' || status === 'replicating';
		return status === filter;
	}

	const filteredReplicas = $derived(
		replicas.filter((r) => matchesStatusFilter(r.status, statusFilter))
	);

	function shortId(id: string): string {
		return id.split('-')[0];
	}
</script>

<svelte:head>
	<title>Replicas - Admin Panel</title>
</svelte:head>

<div class="space-y-6">
	<h2 class="text-xl font-semibold text-white">Replica Management</h2>

	<!-- Summary cards -->
	<div class="grid grid-cols-2 gap-4 md:grid-cols-4">
		<div class="rounded-lg border border-slate-700 bg-slate-800/60 p-4">
			<p class="text-xs font-medium uppercase tracking-wide text-slate-400">Total Replicas</p>
			<p class="mt-1 text-2xl font-bold text-white" data-testid="total-replicas">
				{totalReplicas}
			</p>
		</div>
		<div class="rounded-lg border border-green-700/40 bg-slate-800/60 p-4">
			<p class="text-xs font-medium uppercase tracking-wide text-green-400">Active</p>
			<p class="mt-1 text-2xl font-bold text-green-300" data-testid="active-count">
				{activeCount}
			</p>
		</div>
		<div class="rounded-lg border border-blue-700/40 bg-slate-800/60 p-4">
			<p class="text-xs font-medium uppercase tracking-wide text-blue-400">Syncing</p>
			<p class="mt-1 text-2xl font-bold text-blue-300" data-testid="syncing-count">
				{syncingCount}
			</p>
		</div>
		<div class="rounded-lg border border-red-700/40 bg-slate-800/60 p-4">
			<p class="text-xs font-medium uppercase tracking-wide text-red-400">Failed</p>
			<p class="mt-1 text-2xl font-bold text-red-300" data-testid="failed-count">
				{failedCount}
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
			<option value="all">All</option>
			<option value="active">Active</option>
			<option value="syncing">Syncing</option>
			<option value="provisioning">Provisioning</option>
			<option value="failed">Failed</option>
			<option value="removing">Removing</option>
		</select>
	</div>

	<!-- Replica table -->
	{#if replicas.length === 0}
		<div class="rounded-lg border border-slate-700 bg-slate-800/40 p-8 text-center">
			<p class="text-slate-400">No replicas found.</p>
		</div>
	{:else}
		<div class="overflow-x-auto rounded-lg border border-slate-700">
			<table class="w-full text-left text-sm">
				<thead
					class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
				>
					<tr>
						<th class="px-4 py-3">Index</th>
						<th class="px-4 py-3">Status</th>
						<th class="px-4 py-3">Primary Region</th>
						<th class="px-4 py-3">Replica Region</th>
						<th class="px-4 py-3">Lag</th>
						<th class="px-4 py-3">Primary VM</th>
						<th class="px-4 py-3">Replica VM</th>
						<th class="px-4 py-3">Customer</th>
						<th class="px-4 py-3">Created</th>
					</tr>
				</thead>
				<tbody data-testid="replicas-table-body" class="divide-y divide-slate-700/50">
					{#each filteredReplicas as replica (replica.id)}
						<tr class="transition hover:bg-slate-800/40">
							<td class="px-4 py-3 font-medium text-violet-300">{replica.tenant_id}</td>
							<td class="px-4 py-3">
								<span
									class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
										replica.status
									)}"
								>
									{replica.status}
								</span>
							</td>
							<td class="px-4 py-3 text-slate-300">{replica.primary_vm_region}</td>
							<td class="px-4 py-3 text-slate-300">{replica.replica_region}</td>
							<td class="px-4 py-3 font-mono text-sm text-slate-300">
								{replica.lag_ops.toLocaleString()} ops
							</td>
							<td class="px-4 py-3 text-xs text-slate-400">{replica.primary_vm_hostname}</td>
							<td class="px-4 py-3 text-xs text-slate-400">{replica.replica_vm_hostname}</td>
							<td class="px-4 py-3 font-mono text-xs text-slate-400">
								{shortId(replica.customer_id)}
							</td>
							<td class="px-4 py-3 text-xs text-slate-400">
								{formatDate(replica.created_at)}
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>
