<script lang="ts">
	import { invalidate } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { onMount } from 'svelte';
	import type { PageData } from './$types';
	import { adminBadgeColor, formatDate, formatDateTime } from '$lib/format';
	import { capacityDimensions, utilPercent } from '$lib/vm-capacity';
	import type { VmLifecycleEvent, VmLifecycleEventType } from '$lib/admin-client';
	import { hostMetricPresentation } from '../host_metric_presentation';

	let { data } = $props<{ data: PageData }>();
	let autoRefresh = $state(true);

	const LIFECYCLE_EVENT_LABELS: Record<VmLifecycleEventType, string> = {
		detected_dead: 'Detected dead',
		replacement_refused: 'Replacement refused',
		replacement_provisioning: 'Replacement provisioning',
		replacement_booted: 'Replacement booted',
		tenants_replaced: 'Tenants replaced',
		replacement_failed: 'Replacement failed',
		replacement_completed: 'Replacement completed'
	};

	const LIFECYCLE_DETAIL_LABELS = {
		dead_hostname: 'Dead hostname',
		provider: 'Provider',
		provider_vm_id: 'Provider VM ID',
		region: 'Region',
		planned_replacement_hostname: 'Planned replacement hostname',
		failure_phase: 'Failure phase',
		failure_reason: 'Failure reason'
	} as const;

	type LifecycleDetailKey = keyof typeof LIFECYCLE_DETAIL_LABELS;
	type LifecycleDetailRow = {
		key: LifecycleDetailKey | 'guardrail';
		label: string;
		value: string;
	};
	type ReplacementTarget = {
		id: string | null;
		hostname: string | null;
	};
	const lifecycleEvents = $derived(data.lifecycleEvents as VmLifecycleEvent[] | null);

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

	function tenantRowKey(tenant: PageData['tenants'][number]): string {
		return `${tenant.deployment_id}:${tenant.tenant_id}`;
	}

	const dimensions = $derived(capacityDimensions(data.vm.capacity, data.vm.current_load));
	const hostMetricsPresentation = $derived(
		hostMetricPresentation(data.vm.id, data.hostMetrics ?? null)
	);

	function barColor(pct: number): string {
		if (pct >= 85) return 'bg-red-500';
		if (pct >= 60) return 'bg-yellow-500';
		return 'bg-green-500';
	}

	function scalarDetailValue(value: unknown): string | null {
		if (typeof value === 'string') return value;
		if (typeof value === 'number' || typeof value === 'boolean') return String(value);
		return null;
	}

	function trimmedStringDetail(value: unknown): string | null {
		if (typeof value !== 'string') return null;
		const trimmed = value.trim();
		return trimmed.length > 0 ? trimmed : null;
	}

	function lifecycleDetailRows(event: VmLifecycleEvent): LifecycleDetailRow[] {
		const rows: LifecycleDetailRow[] = [];
		if (event.event_type === 'replacement_refused') {
			const guardrail = scalarDetailValue(event.detail.guardrail);
			if (guardrail !== null) {
				rows.push({ key: 'guardrail', label: 'Guardrail', value: guardrail });
			}
		}

		for (const key of Object.keys(LIFECYCLE_DETAIL_LABELS) as LifecycleDetailKey[]) {
			const value = scalarDetailValue(event.detail[key]);
			if (value !== null) {
				rows.push({ key, label: LIFECYCLE_DETAIL_LABELS[key], value });
			}
		}
		return rows;
	}

	function replacementTarget(event: VmLifecycleEvent): ReplacementTarget {
		return {
			id: trimmedStringDetail(event.detail.replacement_vm_id),
			hostname: trimmedStringDetail(event.detail.replacement_hostname)
		};
	}

	function replacementVmHref(replacementVmId: string): `/admin/fleet/${string}` {
		return `/admin/fleet/${encodeURIComponent(replacementVmId)}`;
	}

	onMount(() => {
		const timer = setInterval(() => {
			if (autoRefresh) {
				invalidate(`admin:fleet:detail:${data.vm.id}`);
			}
		}, 5000);

		return () => clearInterval(timer);
	});
</script>

<svelte:head>
	<title>{data.vm.hostname} - VM Detail - Admin Panel</title>
</svelte:head>

<div class="space-y-6">
	<div class="flex items-center justify-between gap-3">
		<div class="flex items-center gap-3">
			<a href={resolve('/admin/fleet')} class="text-sm text-violet-400 hover:text-violet-300"
				>&larr; Fleet</a
			>
			<h2 class="text-xl font-semibold text-white">{data.vm.hostname}</h2>
			<span
				class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
					data.vm.status
				)}"
			>
				{data.vm.status}
			</span>
		</div>
		<label class="flex items-center gap-2 text-sm text-slate-400">
			<input
				type="checkbox"
				bind:checked={autoRefresh}
				class="rounded border-slate-600 bg-slate-800 text-violet-500 focus:ring-violet-500"
				data-testid="vm-detail-auto-refresh-toggle"
			/>
			Auto-refresh (5s)
		</label>
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

	<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5">
		<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">Host metrics</h3>
		{#if hostMetricsPresentation.state === 'missing'}
			<p class="mt-3 text-sm text-slate-400" data-testid="vm-detail-host-metrics-unavailable">
				No host data
			</p>
		{:else if hostMetricsPresentation.state === 'stale'}
			<p class="mt-3 text-sm text-slate-400" data-testid="vm-detail-host-metrics-stale">
				Stale host data
			</p>
		{:else}
			<dl class="mt-4 grid gap-4 text-sm md:grid-cols-4">
				<div>
					<dt class="text-slate-400">Disk</dt>
					<dd class="text-slate-100" data-testid="vm-detail-host-disk">
						{hostMetricsPresentation.diskLabel}
					</dd>
				</div>
				<div>
					<dt class="text-slate-400">CPU</dt>
					<dd class="text-slate-100" data-testid="vm-detail-host-cpu">
						{hostMetricsPresentation.cpuLabel}
					</dd>
				</div>
				<div>
					<dt class="text-slate-400">RAM</dt>
					<dd class="text-slate-100" data-testid="vm-detail-host-ram">
						{hostMetricsPresentation.ramLabel}
					</dd>
				</div>
				<div>
					<dt class="text-slate-400">Network</dt>
					<dd class="text-slate-100" data-testid="vm-detail-host-net">
						{hostMetricsPresentation.networkLabel}
					</dd>
				</div>
			</dl>
		{/if}
	</div>

	<div
		class="rounded-lg border border-slate-700 bg-slate-900/50 p-5"
		data-testid="vm-lifecycle-section"
	>
		<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">
			VM autorepair lifecycle
		</h3>
		{#if lifecycleEvents === null}
			<p class="mt-3 text-sm text-slate-400" data-testid="vm-lifecycle-unavailable">
				VM lifecycle history unavailable.
			</p>
		{:else if lifecycleEvents.length === 0}
			<p class="mt-3 text-sm text-slate-400" data-testid="vm-lifecycle-empty">
				No lifecycle events recorded for this VM.
			</p>
		{:else}
			<ol class="mt-4 space-y-4" data-testid="vm-lifecycle-list">
				{#each lifecycleEvents as event (event.id)}
					{@const detailRows = lifecycleDetailRows(event)}
					{@const replacement = replacementTarget(event)}
					<li
						class="rounded-lg border border-slate-700 bg-slate-800/50 p-4"
						data-testid={`vm-lifecycle-row-${event.id}`}
					>
						<div class="flex flex-wrap items-baseline justify-between gap-2">
							<p class="font-medium text-slate-100">{LIFECYCLE_EVENT_LABELS[event.event_type]}</p>
							<time class="text-xs text-slate-400" datetime={event.created_at}>
								{formatDateTime(event.created_at)}
							</time>
						</div>
						{#if detailRows.length > 0 || replacement.id || replacement.hostname}
							<dl class="mt-3 grid gap-2 text-sm sm:grid-cols-2">
								{#each detailRows as row (`${event.id}:${row.key}`)}
									<div>
										<dt class="text-xs uppercase tracking-wide text-slate-500">{row.label}</dt>
										<dd class="mt-0.5 break-words text-slate-200">{row.value}</dd>
									</div>
								{/each}
								{#if replacement.id}
									<div>
										<dt class="text-xs uppercase tracking-wide text-slate-500">Replacement VM</dt>
										<dd class="mt-0.5 break-words text-slate-200">
											<a
												href={resolve(replacementVmHref(replacement.id))}
												class="text-violet-300 hover:text-violet-200 hover:underline"
												data-testid={`vm-lifecycle-replacement-link-${event.id}`}
											>
												{replacement.hostname ?? replacement.id}
											</a>
										</dd>
									</div>
								{:else if replacement.hostname}
									<div>
										<dt class="text-xs uppercase tracking-wide text-slate-500">Replacement VM</dt>
										<dd class="mt-0.5 break-words text-slate-200">{replacement.hostname}</dd>
									</div>
								{/if}
							</dl>
						{/if}
					</li>
				{/each}
			</ol>
		{/if}
	</div>

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
						{#each data.tenants as tenant (tenantRowKey(tenant))}
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
