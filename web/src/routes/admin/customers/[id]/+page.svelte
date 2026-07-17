<script lang="ts">
	import { applyAction, enhance } from '$app/forms';
	import { invalidate } from '$app/navigation';
	import type { ActionResult, SubmitFunction } from '@sveltejs/kit';
	import type { PageData } from './$types';
	import { adminBadgeColor, formatDate } from '$lib/format';
	import AuditTimeline from './AuditTimeline.svelte';

	type TabId =
		| 'info'
		| 'indexes'
		| 'deployments'
		| 'usage'
		| 'invoices'
		| 'rate-card'
		| 'quotas'
		| 'audit';

	let { data, form } = $props<{ data: PageData; form?: { error?: string; message?: string } }>();
	let activeTab = $state<TabId>('info');

	const tabs: Array<{ id: TabId; label: string }> = [
		{ id: 'info', label: 'Info' },
		{ id: 'indexes', label: 'Indexes' },
		{ id: 'deployments', label: 'Deployments' },
		{ id: 'usage', label: 'Usage' },
		{ id: 'invoices', label: 'Invoices' },
		{ id: 'rate-card', label: 'Rate Card' },
		{ id: 'quotas', label: 'Quotas' },
		{ id: 'audit', label: 'Audit' }
	];

	function centsToDollars(cents: number): string {
		return `$${(cents / 100).toFixed(2)}`;
	}

	function bytesToGb(value: number): string {
		return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB`;
	}

	function tierBadgeClass(tier: string): string {
		switch (tier) {
			case 'active':
				return 'bg-green-500/20 text-green-300 border-green-500/40';
			case 'cold':
				return 'bg-blue-500/20 text-blue-300 border-blue-500/40';
			case 'restoring':
				return 'bg-yellow-500/20 text-yellow-300 border-yellow-500/40';
			case 'pinned':
				return 'bg-purple-500/20 text-purple-300 border-purple-500/40';
			default:
				return 'bg-slate-500/20 text-slate-300 border-slate-500/40';
		}
	}

	const refreshDetailAfterAction: SubmitFunction = () => {
		return async ({ result }: { result: ActionResult }) => {
			await applyAction(result);

			if (result.type === 'success') {
				await invalidate(`admin:customers:detail:${data.tenant.id}`);
			}
		};
	};
</script>

<svelte:head>
	<title>{data.tenant.name} - Customer - Admin Panel</title>
</svelte:head>

<div class="space-y-6">
	<div class="rounded-lg border border-slate-700 bg-slate-900/70 p-5">
		<div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
			<div>
				<h2 class="text-xl font-semibold text-white">{data.tenant.name}</h2>
				<p class="mt-1 text-sm text-slate-400">{data.tenant.email}</p>
				<div class="mt-3">
					<span
						data-testid="customer-status"
						class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
							data.tenant.status
						)}"
					>
						{data.tenant.status}
					</span>
				</div>
			</div>

			<div class="flex flex-wrap gap-2">
				<form method="POST" action="?/syncStripe" use:enhance={refreshDetailAfterAction}>
					<button
						type="submit"
						class="rounded-md border border-blue-500/40 bg-blue-500/20 px-3 py-1.5 text-sm font-medium text-blue-200 hover:bg-blue-500/30"
					>
						Sync Stripe
					</button>
				</form>

				{#if data.tenant.status === 'active'}
					<form method="POST" action="?/suspend" use:enhance={refreshDetailAfterAction}>
						<button
							type="submit"
							data-testid="suspend-button"
							class="rounded-md border border-yellow-500/40 bg-yellow-500/20 px-3 py-1.5 text-sm font-medium text-yellow-200 hover:bg-yellow-500/30"
						>
							Suspend
						</button>
					</form>
				{:else if data.tenant.status === 'suspended'}
					<form method="POST" action="?/reactivate" use:enhance={refreshDetailAfterAction}>
						<button
							type="submit"
							data-testid="reactivate-button"
							class="rounded-md border border-green-500/40 bg-green-500/20 px-3 py-1.5 text-sm font-medium text-green-200 hover:bg-green-500/30"
						>
							Reactivate
						</button>
					</form>
				{/if}

				{#if data.tenant.status !== 'deleted'}
					<form method="POST" action="?/impersonate">
						<button
							type="submit"
							data-testid="impersonate-button"
							class="rounded-md border border-violet-500/40 bg-violet-500/20 px-3 py-1.5 text-sm font-medium text-violet-200 hover:bg-violet-500/30"
						>
							Impersonate
						</button>
					</form>
				{/if}

				<form method="POST" action="?/softDelete">
					<button
						type="submit"
						data-testid="soft-delete-button"
						class="rounded-md border border-red-500/40 bg-red-500/20 px-3 py-1.5 text-sm font-medium text-red-200 hover:bg-red-500/30"
					>
						Soft Delete
					</button>
				</form>
			</div>
		</div>

		{#if form?.error}
			<p
				class="mt-3 rounded-md border border-red-500/40 bg-red-950/30 px-3 py-2 text-sm text-red-200"
			>
				{form.error}
			</p>
		{:else if form?.message}
			<p
				class="mt-3 rounded-md border border-green-500/40 bg-green-950/30 px-3 py-2 text-sm text-green-200"
			>
				{form.message}
			</p>
		{/if}
	</div>

	<div class="flex flex-wrap gap-2">
		{#each tabs as tab (tab.id)}
			<button
				type="button"
				onclick={() => (activeTab = tab.id)}
				class="rounded-md border px-3 py-1.5 text-sm font-medium transition {activeTab === tab.id
					? 'border-violet-500/70 bg-violet-500/20 text-violet-200'
					: 'border-slate-600 bg-slate-800 text-slate-300 hover:border-slate-500'}"
			>
				{tab.label}
			</button>
		{/each}
	</div>

	{#if activeTab === 'info'}
		<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5">
			<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">Customer Info</h3>
			<dl class="mt-4 grid gap-4 text-sm md:grid-cols-2">
				<div>
					<dt class="text-slate-400">Name</dt>
					<dd class="text-slate-100">{data.tenant.name}</dd>
				</div>
				<div>
					<dt class="text-slate-400">Email</dt>
					<dd class="text-slate-100">{data.tenant.email}</dd>
				</div>
				<div>
					<dt class="text-slate-400">Status</dt>
					<dd class="text-slate-100">{data.tenant.status}</dd>
				</div>
				<div>
					<dt class="text-slate-400">Created</dt>
					<dd class="text-slate-100">{formatDate(data.tenant.created_at)}</dd>
				</div>
				<div>
					<dt class="text-slate-400">Stripe Customer ID</dt>
					<dd class="font-mono text-xs text-slate-300">{data.tenant.stripe_customer_id ?? '—'}</dd>
				</div>
			</dl>
		</div>
	{/if}

	{#if activeTab === 'indexes'}
		<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5">
			<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">Indexes</h3>
			{#if data.indexes === null}
				<p class="mt-3 text-sm text-slate-400">Index data unavailable.</p>
			{:else if data.indexes.length === 0}
				<p class="mt-3 text-sm text-slate-400">No indexes found for this customer.</p>
			{:else}
				<div class="mt-3 overflow-x-auto rounded-lg border border-slate-700">
					<table class="w-full text-left text-sm">
						<thead
							class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
						>
							<tr>
								<th class="px-4 py-3">Name</th>
								<th class="px-4 py-3">Region</th>
								<th class="px-4 py-3">Status</th>
								<th class="px-4 py-3">Tier</th>
								<th class="px-4 py-3">Entries</th>
								<th class="px-4 py-3">Action</th>
							</tr>
						</thead>
						<tbody class="divide-y divide-slate-700/50">
							{#each data.indexes as index (index.name)}
								<tr>
									<td class="px-4 py-3 text-slate-100">{index.name}</td>
									<td class="px-4 py-3 text-slate-300">{index.region}</td>
									<td class="px-4 py-3 text-slate-300">{index.status}</td>
									<td class="px-4 py-3">
										<span
											data-testid="tier-badge"
											class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {tierBadgeClass(
												index.tier ?? 'active'
											)}"
										>
											{index.tier ?? 'active'}
										</span>
									</td>
									<td class="px-4 py-3 text-slate-300">{index.entries.toLocaleString()}</td>
									<td class="px-4 py-3">
										{#if index.tier === 'cold'}
											<button
												type="button"
												data-testid="index-restore-button"
												class="rounded-md border border-green-500/40 bg-green-500/20 px-2 py-1 text-xs font-medium text-green-200 hover:bg-green-500/30"
											>
												Restore
											</button>
										{/if}
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{/if}
		</div>
	{/if}

	{#if activeTab === 'deployments'}
		<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5">
			<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">Deployments</h3>
			{#if data.deployments === null}
				<p class="mt-3 text-sm text-slate-400">Deployment data unavailable.</p>
			{:else if data.deployments.length === 0}
				<p class="mt-3 text-sm text-slate-400">No deployments found for this customer.</p>
			{:else}
				<div class="mt-3 overflow-x-auto rounded-lg border border-slate-700">
					<table class="w-full text-left text-sm">
						<thead
							class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
						>
							<tr>
								<th class="px-4 py-3">Region</th>
								<th class="px-4 py-3">Status</th>
								<th class="px-4 py-3">Health</th>
								<th class="px-4 py-3">URL</th>
								<th class="px-4 py-3">Action</th>
							</tr>
						</thead>
						<tbody class="divide-y divide-slate-700/50">
							{#each data.deployments as deployment (deployment.id)}
								<tr>
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
									<td class="px-4 py-3 text-xs text-slate-400">{deployment.flapjack_url ?? '—'}</td>
									<td class="px-4 py-3">
										<form
											method="POST"
											action="?/terminateDeployment"
											data-testid="terminate-deployment-form"
											use:enhance={refreshDetailAfterAction}
										>
											<input type="hidden" name="deployment_id" value={deployment.id} />
											<button
												type="submit"
												data-testid="terminate-deployment-button"
												class="rounded-md border border-red-500/40 bg-red-500/20 px-2 py-1 text-xs font-medium text-red-200 hover:bg-red-500/30"
											>
												Terminate
											</button>
										</form>
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{/if}
		</div>
	{/if}

	{#if activeTab === 'usage'}
		<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5">
			<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">Usage</h3>
			{#if data.usage}
				<div class="mt-3 grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-4">
					<div class="rounded-md border border-slate-700 bg-slate-800/60 p-3">
						<p class="text-xs uppercase tracking-wide text-slate-400">Searches</p>
						<p class="mt-1 text-lg font-semibold text-white">
							{data.usage.total_search_requests.toLocaleString()}
						</p>
					</div>
					<div class="rounded-md border border-slate-700 bg-slate-800/60 p-3">
						<p class="text-xs uppercase tracking-wide text-slate-400">Writes</p>
						<p class="mt-1 text-lg font-semibold text-white">
							{data.usage.total_write_operations.toLocaleString()}
						</p>
					</div>
					<div class="rounded-md border border-slate-700 bg-slate-800/60 p-3">
						<p class="text-xs uppercase tracking-wide text-slate-400">Avg Storage (GB)</p>
						<p class="mt-1 text-lg font-semibold text-white">
							{data.usage.avg_storage_gb.toFixed(2)}
						</p>
					</div>
					<div class="rounded-md border border-slate-700 bg-slate-800/60 p-3">
						<p class="text-xs uppercase tracking-wide text-slate-400">Avg Documents</p>
						<p class="mt-1 text-lg font-semibold text-white">
							{data.usage.avg_document_count.toLocaleString()}
						</p>
					</div>
				</div>
			{:else}
				<p class="mt-3 text-sm text-slate-400">Usage data unavailable.</p>
			{/if}
		</div>
	{/if}

	{#if activeTab === 'invoices'}
		<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5">
			<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">Invoices</h3>
			{#if data.invoices === null}
				<p class="mt-3 text-sm text-slate-400">Invoice data unavailable.</p>
			{:else if data.invoices.length === 0}
				<p class="mt-3 text-sm text-slate-400">No invoices found for this customer.</p>
			{:else}
				<div class="mt-3 overflow-x-auto rounded-lg border border-slate-700">
					<table class="w-full text-left text-sm">
						<thead
							class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
						>
							<tr>
								<th class="px-4 py-3">Period</th>
								<th class="px-4 py-3">Amount</th>
								<th class="px-4 py-3">Status</th>
								<th class="px-4 py-3">Created</th>
							</tr>
						</thead>
						<tbody class="divide-y divide-slate-700/50">
							{#each data.invoices as invoice (invoice.id)}
								<tr>
									<td class="px-4 py-3 text-slate-300">
										{invoice.period_start} - {invoice.period_end}
									</td>
									<td class="px-4 py-3 text-slate-100">{centsToDollars(invoice.total_cents)}</td>
									<td class="px-4 py-3">
										<span
											class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
												invoice.status
											)}"
										>
											{invoice.status}
										</span>
									</td>
									<td class="px-4 py-3 text-xs text-slate-400">{formatDate(invoice.created_at)}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{/if}
		</div>
	{/if}

	{#if activeTab === 'rate-card'}
		<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5">
			<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">Rate Card</h3>
			{#if data.rateCard}
				<div class="mt-3 grid grid-cols-1 gap-4 text-sm md:grid-cols-2">
					<div>
						<p class="text-slate-400">Name</p>
						<p class="text-slate-100">{data.rateCard.name}</p>
					</div>
					<div>
						<p class="text-slate-400">Dedicated minimum</p>
						<p class="text-slate-100">{centsToDollars(data.rateCard.minimum_spend_cents)}</p>
					</div>
					<div>
						<p class="text-slate-400">Shared minimum</p>
						<p class="text-slate-100">{centsToDollars(data.rateCard.shared_minimum_spend_cents)}</p>
					</div>
					<div>
						<p class="text-slate-400">Storage per MB / month</p>
						<p class="text-slate-100">{data.rateCard.storage_rate_per_mb_month}</p>
					</div>
					<div>
						<p class="text-slate-400">Cold storage per GB / month</p>
						<p class="text-slate-100">{data.rateCard.cold_storage_rate_per_gb_month}</p>
					</div>
					<div>
						<p class="text-slate-400">Object storage per GB / month</p>
						<p class="text-slate-100">{data.rateCard.object_storage_rate_per_gb_month}</p>
					</div>
					<div>
						<p class="text-slate-400">Object storage egress per GB</p>
						<p class="text-slate-100">{data.rateCard.object_storage_egress_rate_per_gb}</p>
					</div>
				</div>
			{:else}
				<p class="mt-3 text-sm text-slate-400">Rate card unavailable.</p>
			{/if}
		</div>
	{/if}

	{#if activeTab === 'quotas'}
		<div class="rounded-lg border border-slate-700 bg-slate-900/50 p-5">
			<h3 class="text-sm font-semibold uppercase tracking-wide text-slate-300">Index Quotas</h3>
			{#if data.quotas}
				<form
					method="POST"
					action="?/updateQuotas"
					data-testid="update-quotas-form"
					class="mt-4 grid grid-cols-1 gap-3 md:grid-cols-4"
					use:enhance={refreshDetailAfterAction}
				>
					<label class="flex flex-col gap-1 text-xs uppercase tracking-wide text-slate-400">
						Max Query RPS
						<input
							type="number"
							name="max_query_rps"
							min="1"
							value={data.quotas.defaults.max_query_rps}
							class="rounded-md border border-slate-600 bg-slate-800 px-3 py-1.5 text-sm text-slate-100"
						/>
					</label>
					<label class="flex flex-col gap-1 text-xs uppercase tracking-wide text-slate-400">
						Max Write RPS
						<input
							type="number"
							name="max_write_rps"
							min="1"
							value={data.quotas.defaults.max_write_rps}
							class="rounded-md border border-slate-600 bg-slate-800 px-3 py-1.5 text-sm text-slate-100"
						/>
					</label>
					<label class="flex flex-col gap-1 text-xs uppercase tracking-wide text-slate-400">
						Max Storage Bytes
						<input
							type="number"
							name="max_storage_bytes"
							min="1"
							value={data.quotas.defaults.max_storage_bytes}
							class="rounded-md border border-slate-600 bg-slate-800 px-3 py-1.5 text-sm text-slate-100"
						/>
					</label>
					<label class="flex flex-col gap-1 text-xs uppercase tracking-wide text-slate-400">
						Max Indexes
						<input
							type="number"
							name="max_indexes"
							min="1"
							value={data.quotas.defaults.max_indexes}
							class="rounded-md border border-slate-600 bg-slate-800 px-3 py-1.5 text-sm text-slate-100"
						/>
					</label>
					<div class="md:col-span-4">
						<button
							type="submit"
							data-testid="update-quotas-button"
							class="rounded-md border border-slate-500/60 bg-slate-700 px-3 py-1.5 text-sm font-medium text-slate-100 hover:bg-slate-600"
						>
							Update quotas
						</button>
					</div>
				</form>

				{#if data.quotas.indexes.length === 0}
					<p class="mt-3 text-sm text-slate-400">No indexes found for this customer.</p>
				{:else}
					<div class="mt-4 overflow-x-auto rounded-lg border border-slate-700">
						<table class="w-full text-left text-sm">
							<thead
								class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
							>
								<tr>
									<th class="px-4 py-3">Index</th>
									<th class="px-4 py-3">Query RPS</th>
									<th class="px-4 py-3">Write RPS</th>
									<th class="px-4 py-3">Storage</th>
									<th class="px-4 py-3">Max Indexes</th>
								</tr>
							</thead>
							<tbody class="divide-y divide-slate-700/50">
								{#each data.quotas.indexes as quota (quota.index_name)}
									<tr>
										<td class="px-4 py-3 text-slate-100">{quota.index_name}</td>
										<td class="px-4 py-3 text-slate-300">{quota.effective.max_query_rps}</td>
										<td class="px-4 py-3 text-slate-300">{quota.effective.max_write_rps}</td>
										<td class="px-4 py-3 text-slate-300">
											{bytesToGb(quota.effective.max_storage_bytes)}
										</td>
										<td class="px-4 py-3 text-slate-300">{quota.effective.max_indexes}</td>
									</tr>
								{/each}
							</tbody>
						</table>
					</div>
				{/if}
			{:else}
				<p class="mt-3 text-sm text-slate-400">Quota data unavailable.</p>
			{/if}
		</div>
	{/if}

	{#if activeTab === 'audit'}
		<AuditTimeline audit={data.audit} />
	{/if}
</div>
