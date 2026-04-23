<script lang="ts">
	import { resolve } from '$app/paths';
	import type { PageData } from './$types';
	import { adminBadgeColor, formatDate } from '$lib/format';

	let { data } = $props<{ data: PageData }>();

	function shortId(id: string): string {
		return id.split('-')[0];
	}

	function providerVmIdHint(provider: string): string {
		switch (provider) {
			case 'aws':
				return 'AWS instance ID';
			case 'hetzner':
				return 'Hetzner server ID';
			default:
				return `${provider} provider VM ID`;
		}
	}

	type ResourceDimension = { key: string; label: string; used: number; total: number };

	const dimensions: ResourceDimension[] = $derived.by(() => {
		const cap = data.vm.capacity ?? {};
		const load = data.vm.current_load ?? {};
		return Object.keys(cap)
			.filter((k) => typeof cap[k] === 'number' && typeof load[k] === 'number')
			.map((k) => ({
				key: k,
				label: k,
				used: load[k] as number,
				total: cap[k] as number
			}));
	});

	function utilPercent(used: number, total: number): number {
		if (total <= 0) return 0;
		return Math.round((used / total) * 100);
	}

	function barColor(pct: number): string {
		if (pct >= 85) return 'bg-red-500';
		if (pct >= 60) return 'bg-yellow-500';
		return 'bg-green-500';
	}
</script>

<svelte:head>
	<title>{data.vm.hostname} - VM Detail - Admin Panel</title>
</svelte:head>

<div class="space-y-6">
	<div class="flex items-center gap-3">
		<a href={resolve('/admin/fleet')} class="text-sm text-violet-400 hover:text-violet-300">&larr; Fleet</a>
		<h2 class="text-xl font-semibold text-white">{data.vm.hostname}</h2>
		<span
			class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
				data.vm.status
			)}"
		>
			{data.vm.status}
		</span>
	</div>

	<!-- VM Info -->
	<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5" data-testid="vm-info-section">
		<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">VM Info</h3>
		<dl class="mt-4 grid gap-4 text-sm md:grid-cols-3">
			<div>
				<dt class="text-slate-400">Hostname</dt>
				<dd class="text-slate-100">{data.vm.hostname}</dd>
			</div>
			<div>
				<dt class="text-slate-400">Region</dt>
				<dd class="text-slate-100">{data.vm.region}</dd>
			</div>
			<div>
				<dt class="text-slate-400">Provider</dt>
				<dd class="text-slate-100">{data.vm.provider}</dd>
			</div>
			<div>
				<dt class="text-slate-400">Provider VM ID</dt>
				<dd class="text-slate-100">
					{data.vm.provider_vm_id ?? '—'}
					<span class="ml-2 text-xs text-slate-400">{providerVmIdHint(data.vm.provider)}</span>
				</dd>
			</div>
			<div>
				<dt class="text-slate-400">Flapjack URL</dt>
				<dd class="text-xs text-slate-300">{data.vm.flapjack_url}</dd>
			</div>
			<div>
				<dt class="text-slate-400">Created</dt>
				<dd class="text-slate-100">{formatDate(data.vm.created_at)}</dd>
			</div>
			<div>
				<dt class="text-slate-400">Updated</dt>
				<dd class="text-slate-100">{formatDate(data.vm.updated_at)}</dd>
			</div>
		</dl>
	</div>

	<!-- Utilization bars -->
	{#if dimensions.length > 0}
		<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5">
			<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">Utilization</h3>
			<div class="mt-4 space-y-3">
				{#each dimensions as dim (dim.key)}
					{@const pct = utilPercent(dim.used, dim.total)}
					<div data-testid="util-bar-{dim.key}">
						<div class="flex items-center justify-between text-sm">
							<span class="text-slate-300">{dim.label}</span>
							<span class="text-slate-400">{dim.used} / {dim.total} ({pct}%)</span>
						</div>
						<div class="mt-1 h-2 w-full rounded-full bg-slate-700">
							<div
								class="h-2 rounded-full transition-all {barColor(pct)}"
								style="width: {pct}%"
							></div>
						</div>
					</div>
				{/each}
			</div>
		</div>
	{/if}

	<!-- Per-index breakdown -->
	<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5">
		<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">
			Indexes on this VM ({data.tenants.length})
		</h3>
		{#if data.tenants.length === 0}
			<p class="mt-3 text-sm text-slate-400">No indexes assigned to this VM.</p>
		{:else}
			<div class="mt-3 overflow-x-auto rounded-lg border border-slate-700">
				<table class="w-full text-left text-sm" data-testid="tenant-breakdown-table">
					<thead
						class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
					>
						<tr>
							<th class="px-4 py-3">Index</th>
							<th class="px-4 py-3">Customer</th>
							<th class="px-4 py-3">Tier</th>
							<th class="px-4 py-3">Created</th>
						</tr>
					</thead>
					<tbody class="divide-y divide-slate-700/50">
						{#each data.tenants as tenant (tenant.tenant_id)}
							<tr class="transition hover:bg-slate-800/40">
								<td class="px-4 py-3 text-slate-100">{tenant.tenant_id}</td>
								<td class="px-4 py-3 font-mono text-xs text-slate-400">
									{shortId(tenant.customer_id)}
								</td>
								<td class="px-4 py-3">
									<span
										class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
											tenant.tier
										)}"
									>
										{tenant.tier}
									</span>
								</td>
								<td class="px-4 py-3 text-xs text-slate-400">
									{formatDate(tenant.created_at)}
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	</div>
</div>
