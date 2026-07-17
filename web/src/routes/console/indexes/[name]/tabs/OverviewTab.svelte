<script lang="ts">
	import { enhance } from '$app/forms';
	import { invalidateAll } from '$app/navigation';
	import { copyToClipboard } from '$lib/clipboard';
	import { formatBytes, formatNumber, statusLabel } from '$lib/format';
	import type {
		AnalyticsNoResultRateResponse,
		AnalyticsSearchCountResponse,
		AnalyticsStatusResponse,
		AnalyticsTopSearchesResponse,
		Index,
		IndexReplicaSummary,
		InternalRegion
	} from '$lib/api/types';
	import ConnectYourAppCard from './ConnectYourAppCard.svelte';
	import DataManagementCard from './DataManagementCard.svelte';

	type Props = {
		index: Index;
		replicas: IndexReplicaSummary[];
		regions: InternalRegion[];
		availableReplicaRegions: InternalRegion[];
		replicaError: string;
		deleteError: string;
		replicaCreated: boolean;
		analyticsStatus?: AnalyticsStatusResponse | null;
		searchCount?: AnalyticsSearchCountResponse | null;
		noResultRate?: AnalyticsNoResultRateResponse | null;
		topSearches?: AnalyticsTopSearchesResponse | null;
		analyticsUnavailable?: boolean;
		documentsUploadError?: string;
		analyticsTabHref?: string;
	};

	let {
		index,
		replicas,
		regions,
		availableReplicaRegions,
		replicaError,
		deleteError,
		replicaCreated,
		analyticsStatus = null,
		searchCount = null,
		noResultRate = null,
		topSearches = null,
		analyticsUnavailable = false,
		documentsUploadError = '',
		analyticsTabHref = '#'
	}: Props = $props();

	let showAddReplica = $state(false);
	let selectedReplicaRegion = $state('');
	let deleteConfirmName = $state('');
	let showDeleteConfirm = $state(false);
	const topSearchCount = $derived(topSearches?.searches.length ?? 0);
	const totalSearchCount = $derived(searchCount?.count ?? 0);
	const noResultRatePercent = $derived(
		typeof noResultRate?.rate === 'number' ? `${(noResultRate.rate * 100).toFixed(1)}%` : 'N/A'
	);
	const analyticsStatusLabel = $derived(
		analyticsStatus?.enabled === true
			? 'Enabled'
			: analyticsStatus?.enabled === false
				? 'Disabled'
				: 'N/A'
	);
	let overviewImportedDocumentCount = $state<number | null>(null);
	let overviewPendingImportedDocumentCount = $state<number | null>(null);
	let overviewAwaitingUploadResult = $state(false);
	let overviewImportSuccessDismissed = $state(false);
	let overviewLastUploadSucceeded = $state(false);
	const showOverviewImportSuccess = $derived(
		overviewLastUploadSucceeded &&
			overviewImportedDocumentCount !== null &&
			!overviewImportSuccessDismissed &&
			!overviewAwaitingUploadResult
	);

	function handleOverviewImportDocumentCountChange(count: number): void {
		overviewPendingImportedDocumentCount = count;
		overviewAwaitingUploadResult = true;
		overviewImportSuccessDismissed = true;
	}

	function handleOverviewImportUploadSettled(uploadSucceeded: boolean): void {
		const hasPriorSuccessfulImport =
			overviewLastUploadSucceeded && overviewImportedDocumentCount !== null;
		overviewAwaitingUploadResult = false;
		if (!uploadSucceeded) {
			overviewPendingImportedDocumentCount = null;
			// Restore the last confirmed banner after a failed retry until refresh succeeds.
			overviewImportSuccessDismissed = !hasPriorSuccessfulImport;
			return;
		}
		if (overviewPendingImportedDocumentCount !== null) {
			overviewImportedDocumentCount = overviewPendingImportedDocumentCount;
		}
		overviewPendingImportedDocumentCount = null;
		overviewImportSuccessDismissed = false;
		overviewLastUploadSucceeded = true;
	}

	async function refreshOverviewImportSuccess(): Promise<void> {
		try {
			await invalidateAll();
			overviewImportSuccessDismissed = true;
			overviewImportedDocumentCount = null;
			overviewPendingImportedDocumentCount = null;
			overviewAwaitingUploadResult = false;
			overviewLastUploadSucceeded = false;
		} catch {
			// Keep banner/count visible when revalidation fails so import feedback is not lost.
		}
	}
</script>

{#if showOverviewImportSuccess}
	<div
		data-testid="overview-import-success-banner"
		class="mb-6 flex flex-col gap-3 rounded-lg border border-flapjack-mint/60 bg-flapjack-mint/25 p-4 text-sm text-flapjack-ink sm:flex-row sm:items-center sm:justify-between"
		role="status"
	>
		<p>
			Imported {formatNumber(overviewImportedDocumentCount ?? 0)} document{overviewImportedDocumentCount ===
			1
				? ''
				: 's'}. Refresh page to see them
		</p>
		<button
			type="button"
			class="rounded-md border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
			onclick={refreshOverviewImportSuccess}
		>
			Refresh
		</button>
	</div>
{/if}

<div
	class="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4"
	data-testid="stats-section"
	data-region-count={regions.length}
>
	<div class="rounded-lg bg-white p-4 shadow">
		<p class="text-sm font-medium text-flapjack-ink/60">Entries</p>
		<p class="mt-1 text-2xl font-semibold text-flapjack-ink" data-testid="stat-entries-value">
			{formatNumber(index.entries)}
		</p>
	</div>
	<div class="rounded-lg bg-white p-4 shadow">
		<p class="text-sm font-medium text-flapjack-ink/60">Data Size</p>
		<p class="mt-1 text-2xl font-semibold text-flapjack-ink" data-testid="stat-data-size-value">
			{formatBytes(index.data_size_bytes)}
		</p>
	</div>
	<div class="rounded-lg bg-white p-4 shadow">
		<p class="text-sm font-medium text-flapjack-ink/60">Region</p>
		<p class="mt-1 text-2xl font-semibold text-flapjack-ink" data-testid="stat-region-value">
			{index.region}
		</p>
	</div>
	<div class="rounded-lg bg-white p-4 shadow">
		<p class="text-sm font-medium text-flapjack-ink/60">Endpoint</p>
		{#if index.endpoint}
			<div class="mt-1 flex items-center gap-2">
				<code class="truncate text-sm text-flapjack-ink">{index.endpoint}</code>
				<button
					type="button"
					onclick={(event) =>
						void copyToClipboard(index.endpoint ?? '', event.currentTarget as HTMLButtonElement)}
					class="shrink-0 rounded border border-flapjack-ink/30 px-2 py-0.5 text-xs text-flapjack-ink/70 hover:bg-flapjack-cream/80"
				>
					Copy
				</button>
			</div>
		{:else}
			<p class="mt-1 text-sm text-flapjack-ink/50">Preparing...</p>
		{/if}
	</div>
</div>

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="overview-analytics-summary">
	<div class="mb-4 flex items-center justify-between">
		<h2 class="text-lg font-medium text-flapjack-ink">Analytics Summary</h2>
		<!-- eslint-disable svelte/no-navigation-without-resolve -->
		<a
			href={analyticsTabHref}
			class="text-sm font-medium text-flapjack-rose hover:underline"
			data-testid="overview-view-analytics-link">View Details</a
		>
		<!-- eslint-enable svelte/no-navigation-without-resolve -->
	</div>
	<div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
		<div class="rounded-md border border-flapjack-ink/10 bg-flapjack-cream/60 p-3">
			<p class="text-xs uppercase tracking-wide text-flapjack-ink/60">Searches (7d)</p>
			<p class="mt-1 text-xl font-semibold text-flapjack-ink">{formatNumber(totalSearchCount)}</p>
		</div>
		<div class="rounded-md border border-flapjack-ink/10 bg-flapjack-cream/60 p-3">
			<p class="text-xs uppercase tracking-wide text-flapjack-ink/60">No Results</p>
			<p class="mt-1 text-xl font-semibold text-flapjack-ink">{noResultRatePercent}</p>
		</div>
		<div class="rounded-md border border-flapjack-ink/10 bg-flapjack-cream/60 p-3">
			<p class="text-xs uppercase tracking-wide text-flapjack-ink/60">Top Queries</p>
			<p class="mt-1 text-xl font-semibold text-flapjack-ink">{formatNumber(topSearchCount)}</p>
		</div>
	</div>
	<div
		class="mt-4 rounded-md border border-dashed border-flapjack-ink/30 bg-flapjack-cream/40 p-4 text-sm text-flapjack-ink/70"
		data-testid="overview-analytics-sparkline"
	>
		Sparkline preview (7-day trend)
	</div>
	<p class="mt-2 text-sm text-flapjack-ink/70">
		Analytics status: <span class="font-medium text-flapjack-ink">{analyticsStatusLabel}</span>
	</p>
	{#if (analyticsUnavailable || analyticsStatus === null) && index.entries > 0}
		<div
			class="mt-3 rounded-md bg-flapjack-yellow/25 p-3 text-sm text-flapjack-ink/80"
			role="alert"
		>
			<p>Analytics summary unavailable.</p>
			<button
				type="button"
				class="mt-2 rounded-md border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
				onclick={() => {
					void invalidateAll();
				}}
			>
				Retry
			</button>
		</div>
	{/if}
</div>

<DataManagementCard
	{index}
	{documentsUploadError}
	onOverviewImportDocumentCountChange={handleOverviewImportDocumentCountChange}
	onOverviewImportUploadSettled={handleOverviewImportUploadSettled}
/>

<ConnectYourAppCard {index} />

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="replicas-section">
	<div class="mb-4 flex items-center justify-between">
		<h2 class="text-lg font-medium text-flapjack-ink">Read Replicas</h2>
		{#if availableReplicaRegions.length > 0}
			<button
				type="button"
				onclick={() => {
					showAddReplica = !showAddReplica;
				}}
				class="rounded-md bg-flapjack-rose px-3 py-1.5 text-sm font-medium text-white hover:bg-flapjack-plum"
			>
				Add Replica
			</button>
		{/if}
	</div>

	{#if replicaError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{replicaError}
		</div>
	{/if}

	{#if replicaCreated}
		<div
			class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Replica created. It will begin syncing shortly.
		</div>
	{/if}

	{#if showAddReplica}
		<div class="mb-4 rounded-md border border-flapjack-rose/30 bg-flapjack-rose/10 p-4">
			<form method="POST" action="?/createReplica" use:enhance>
				<label for="replica-region" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
					>Target region</label
				>
				<div class="flex gap-3">
					<select
						id="replica-region"
						name="region"
						bind:value={selectedReplicaRegion}
						class="flex-1 rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
					>
						<option value="" disabled>Select a region...</option>
						{#each availableReplicaRegions as region (region.id)}
							<option value={region.id}>{region.display_name} ({region.id})</option>
						{/each}
					</select>
					<button
						type="submit"
						disabled={!selectedReplicaRegion}
						class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-50"
					>
						Create
					</button>
					<button
						type="button"
						onclick={() => {
							showAddReplica = false;
							selectedReplicaRegion = '';
						}}
						class="rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
					>
						Cancel
					</button>
				</div>
			</form>
		</div>
	{/if}

	{#if replicas.length === 0}
		<p class="text-sm text-flapjack-ink/60">
			No read replicas. Add a replica in another region for lower-latency reads.
		</p>
	{:else}
		<div class="overflow-hidden rounded-lg border">
			<table class="w-full text-left text-sm">
				<thead
					class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
				>
					<tr>
						<th class="px-4 py-2">Region</th>
						<th class="px-4 py-2">Status</th>
						<th class="px-4 py-2">Lag (ops)</th>
						<th class="px-4 py-2"></th>
					</tr>
				</thead>
				<tbody class="divide-y">
					{#each replicas as replica (replica.id)}
						<tr>
							<td class="px-4 py-2 text-flapjack-ink">{replica.replica_region}</td>
							<td class="px-4 py-2">
								<span
									class="inline-flex rounded-full px-2 py-0.5 text-xs font-medium
											{replica.status === 'active'
										? 'bg-flapjack-mint/35 text-flapjack-ink'
										: replica.status === 'syncing' || replica.status === 'provisioning'
											? 'bg-flapjack-yellow/30 text-flapjack-ink/80'
											: replica.status === 'failed'
												? 'bg-flapjack-rose/15 text-flapjack-plum'
												: 'bg-flapjack-cream/70 text-flapjack-ink'}"
								>
									{statusLabel(replica.status)}
								</span>
							</td>
							<td class="px-4 py-2 text-flapjack-ink/70">{replica.lag_ops}</td>
							<td class="px-4 py-2 text-right">
								<form method="POST" action="?/deleteReplica" use:enhance>
									<input type="hidden" name="replica_id" value={replica.id} />
									<button
										type="submit"
										class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
										onclick={(e) => {
											if (!confirm(`Remove read replica in ${replica.replica_region}?`)) {
												e.preventDefault();
											}
										}}
									>
										Remove
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

<div
	class="rounded-lg border border-flapjack-rose/35 bg-white p-6 shadow"
	data-testid="danger-zone"
>
	<h2 class="mb-2 text-lg font-medium text-flapjack-plum">Danger Zone</h2>
	<p class="mb-4 text-sm text-flapjack-ink/70">
		Deleting an index is permanent. All data in the index will be lost.
	</p>

	{#if deleteError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{deleteError}
		</div>
	{/if}

	{#if showDeleteConfirm}
		<form method="POST" action="?/delete" use:enhance>
			<p class="mb-2 text-sm text-flapjack-ink/80">
				Type <strong>{index.name}</strong> to confirm:
			</p>
			<input
				type="text"
				bind:value={deleteConfirmName}
				placeholder={index.name}
				class="mb-3 w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-plum focus:ring-1 focus:ring-flapjack-plum"
			/>
			<div class="flex gap-3">
				<button
					type="submit"
					disabled={deleteConfirmName !== index.name}
					class="rounded-md bg-flapjack-plum px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum/90 disabled:cursor-not-allowed disabled:opacity-50"
				>
					Permanently Delete
				</button>
				<button
					type="button"
					onclick={() => {
						showDeleteConfirm = false;
						deleteConfirmName = '';
					}}
					class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
				>
					Cancel
				</button>
			</div>
		</form>
	{:else}
		<button
			type="button"
			onclick={() => {
				showDeleteConfirm = true;
			}}
			class="rounded-md border border-flapjack-rose/45 px-4 py-2 text-sm font-medium text-flapjack-plum hover:bg-flapjack-rose/10"
		>
			Delete this index
		</button>
	{/if}
</div>
