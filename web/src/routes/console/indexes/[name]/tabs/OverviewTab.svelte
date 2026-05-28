<script lang="ts">
	import { applyAction, deserialize, enhance } from '$app/forms';
	import { invalidateAll } from '$app/navigation';
	import { tick } from 'svelte';
	import { copyToClipboard } from '$lib/clipboard';
	import { formatBytes, formatNumber, statusLabel } from '$lib/format';
	import type {
		AnalyticsNoResultRateResponse,
		AnalyticsSearchCountResponse,
		AnalyticsStatusResponse,
		AnalyticsTopSearchesResponse,
		Index,
		IndexReplicaSummary,
		InternalRegion,
		SearchResult
	} from '$lib/api/types';
	import ConnectYourAppCard from './ConnectYourAppCard.svelte';
	import { MAX_DOCUMENT_UPLOAD_BYTES, parseUploadFileRecords } from './documents-file-parser';
	import { buildAddObjectBatchPayload } from './documents_batch_payload';

	type Props = {
		index: Index;
		replicas: IndexReplicaSummary[];
		regions: InternalRegion[];
		availableReplicaRegions: InternalRegion[];
		searchResult: SearchResult | null;
		searchQuery: string;
		searchError: string;
		replicaError: string;
		deleteError: string;
		replicaCreated: boolean;
		analyticsStatus?: AnalyticsStatusResponse | null;
		searchCount?: AnalyticsSearchCountResponse | null;
		noResultRate?: AnalyticsNoResultRateResponse | null;
		topSearches?: AnalyticsTopSearchesResponse | null;
		analyticsUnavailable?: boolean;
		documentsUploadSuccess?: boolean;
		documentsUploadError?: string;
		settingsTabHref?: string;
		analyticsTabHref?: string;
		documentsTabHref?: string;
	};

	let {
		index,
		replicas,
		regions,
		availableReplicaRegions,
		searchResult,
		searchQuery,
		searchError,
		replicaError,
		deleteError,
		replicaCreated,
		analyticsStatus = null,
		searchCount = null,
		noResultRate = null,
		topSearches = null,
		analyticsUnavailable = false,
		documentsUploadSuccess = false,
		documentsUploadError = '',
		settingsTabHref = '#',
		analyticsTabHref = '#',
		documentsTabHref = '#'
	}: Props = $props();

	let showAddReplica = $state(false);
	let selectedReplicaRegion = $state('');
	let deleteConfirmName = $state('');
	let showDeleteConfirm = $state(false);
	let exportInFlight = $state(false);
	let importInFlight = $state(false);
	let importBatchPayload = $state('');
	let localDataManagementError = $state('');
	let importFileInputElement = $state<HTMLInputElement | null>(null);
	let importFormElement = $state<HTMLFormElement | null>(null);
	const indexProvisioned = $derived(index.endpoint !== null);
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
	const dataManagementAlert = $derived(localDataManagementError || documentsUploadError);

	const EXPORT_HITS_PER_PAGE = 1000;
	const EXPORT_ENTRY_LIMIT = 10000;
	const IMPORT_REFRESH_HITS_PER_PAGE = 20;

	type ExportBrowsePage = {
		cursor: string | null;
		hits: Record<string, unknown>[];
	};

	function setLocalDataManagementError(message: string): void {
		localDataManagementError = message;
	}

	function clearLocalDataManagementError(): void {
		localDataManagementError = '';
	}

	function exportFilenameForIndex(indexName: string): string {
		const dayStamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
		return `${indexName}-export-${dayStamp}.json`;
	}

	function browsePageFromActionResult(result: unknown): ExportBrowsePage {
		if (!result || typeof result !== 'object' || !('type' in result)) {
			throw new Error('Unexpected browse response');
		}

		const actionResult = result as {
			type: string;
			data?: Record<string, unknown>;
		};

		if (actionResult.type === 'failure') {
			const errorMessage = actionResult.data?.documentsBrowseError;
			if (typeof errorMessage === 'string' && errorMessage.trim().length > 0) {
				throw new Error(errorMessage);
			}
			throw new Error('Failed to browse documents for export');
		}
		if (actionResult.type !== 'success') {
			throw new Error('Failed to browse documents for export');
		}

		const documents = actionResult.data?.documents;
		if (!documents || typeof documents !== 'object') {
			throw new Error('Browse response did not include documents');
		}

		const docs = documents as Record<string, unknown>;
		const hits = Array.isArray(docs.hits)
			? docs.hits.filter(
					(hit): hit is Record<string, unknown> => typeof hit === 'object' && hit !== null
				)
			: [];
		const cursor = typeof docs.cursor === 'string' && docs.cursor.length > 0 ? docs.cursor : null;
		return { cursor, hits };
	}

	async function fetchBrowsePageForExport(cursor: string | null): Promise<ExportBrowsePage> {
		const body = new FormData();
		body.set('query', '');
		body.set('hitsPerPage', String(EXPORT_HITS_PER_PAGE));
		if (cursor) {
			body.set('cursor', cursor);
		}

		const response = await fetch('?/browseDocuments', {
			method: 'POST',
			headers: {
				'x-sveltekit-action': 'true'
			},
			body
		});
		const actionResult = deserialize(await response.text());
		if (actionResult.type === 'redirect' || actionResult.type === 'error') {
			await applyAction(actionResult);
			throw new Error('Failed to browse documents for export');
		}

		return browsePageFromActionResult(actionResult);
	}

	function downloadExport(records: Record<string, unknown>[]): void {
		const blob = new Blob([JSON.stringify(records, null, 2)], { type: 'application/json' });
		const objectUrl = URL.createObjectURL(blob);
		const anchor = document.createElement('a');
		anchor.href = objectUrl;
		anchor.download = exportFilenameForIndex(index.name);
		anchor.style.display = 'none';
		document.body.appendChild(anchor);
		anchor.click();
		anchor.remove();
		URL.revokeObjectURL(objectUrl);
	}

	async function handleOverviewExportClick(): Promise<void> {
		if (!indexProvisioned || exportInFlight) return;

		clearLocalDataManagementError();
		if (index.entries > EXPORT_ENTRY_LIMIT) {
			setLocalDataManagementError('Export is limited to indexes with 10,000 entries or fewer');
			return;
		}
		if (index.entries === 0) {
			downloadExport([]);
			return;
		}

		exportInFlight = true;
		try {
			const exportedHits: Record<string, unknown>[] = [];
			let cursor: string | null = null;
			do {
				const page = await fetchBrowsePageForExport(cursor);
				exportedHits.push(...page.hits);
				cursor = page.cursor;
			} while (cursor);
			downloadExport(exportedHits);
		} catch (error) {
			setLocalDataManagementError(
				error instanceof Error ? error.message : 'Failed to export documents'
			);
		} finally {
			exportInFlight = false;
		}
	}

	function openImportPicker(): void {
		if (!indexProvisioned || importInFlight) return;
		clearLocalDataManagementError();
		importFileInputElement?.click();
	}

	async function handleOverviewImportFileChange(event: Event): Promise<void> {
		const input = event.currentTarget;
		if (!(input instanceof HTMLInputElement)) return;
		const file = input.files?.[0];
		input.value = '';
		if (!file) return;

		clearLocalDataManagementError();
		if (file.size > MAX_DOCUMENT_UPLOAD_BYTES) {
			setLocalDataManagementError('File exceeds 100MB limit');
			return;
		}

		try {
			const parsedFile = await parseUploadFileRecords(file);
			importBatchPayload = buildAddObjectBatchPayload(parsedFile.records);
			await tick();
			importFormElement?.requestSubmit();
		} catch (error) {
			setLocalDataManagementError(error instanceof Error ? error.message : 'Failed to parse file');
		}
	}
</script>

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

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="overview-data-management">
	<h2 class="mb-2 text-lg font-medium text-flapjack-ink">Data Management</h2>
	<p class="mb-4 text-sm text-flapjack-ink/70">
		Export your index contents or import new records using existing document actions.
	</p>
	<div class="flex flex-wrap gap-3">
		<button
			type="button"
			class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-50"
			data-testid="overview-export-btn"
			disabled={!indexProvisioned || exportInFlight || importInFlight}
			onclick={() => {
				void handleOverviewExportClick();
			}}
		>
			{exportInFlight ? 'Exporting…' : 'Export Index'}
		</button>
		<button
			type="button"
			class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80 disabled:cursor-not-allowed disabled:opacity-50"
			data-testid="overview-import-btn"
			disabled={!indexProvisioned || exportInFlight || importInFlight}
			onclick={openImportPicker}
		>
			{importInFlight ? 'Importing…' : 'Import Documents'}
		</button>
	</div>
	<input
		bind:this={importFileInputElement}
		id="overview-import-file"
		aria-label="Import JSON or CSV file"
		type="file"
		accept=".json,.csv,application/json,text/csv"
		onchange={handleOverviewImportFileChange}
		class="sr-only"
	/>
	<form
		bind:this={importFormElement}
		method="POST"
		action="?/uploadDocuments"
		use:enhance={() => {
			importInFlight = true;
			return async ({ update }) => {
				await update();
				importInFlight = false;
				importBatchPayload = '';
			};
		}}
		class="hidden"
	>
		<input type="hidden" name="batch" value={importBatchPayload} />
		<input type="hidden" name="query" value="" />
		<input type="hidden" name="hitsPerPage" value={String(IMPORT_REFRESH_HITS_PER_PAGE)} />
	</form>
	{#if !indexProvisioned}
		<p class="mt-3 text-sm text-flapjack-ink/60">Available once your index is provisioned</p>
	{/if}
	{#if documentsUploadSuccess}
		<div
			class="mt-3 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Documents uploaded.
		</div>
	{/if}
	{#if dataManagementAlert}
		<div
			class="mt-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
			role="alert"
			aria-label="overview-export-import-alert"
		>
			{dataManagementAlert}
		</div>
	{/if}
</div>

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="search-widget">
	<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Test Search</h2>
	<form method="POST" action="?/search" use:enhance class="flex gap-3">
		<input
			type="text"
			name="query"
			value={searchQuery}
			placeholder="Search your index..."
			class="flex-1 rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		/>
		<button
			type="submit"
			class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
		>
			Search
		</button>
	</form>

	{#if searchError}
		<div class="mt-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{searchError}
		</div>
	{/if}

	{#if searchResult}
		<div class="mt-4" data-testid="search-results">
			<div class="mb-2 flex items-center gap-4 text-sm text-flapjack-ink/60">
				<span>{searchResult.nbHits} hit{searchResult.nbHits !== 1 ? 's' : ''}</span>
				<span>{searchResult.processingTimeMs}ms</span>
			</div>
			{#if searchResult.hits.length > 0}
				<div class="space-y-2">
					{#each searchResult.hits as hit, idx (idx)}
						<pre
							class="overflow-x-auto rounded-md bg-flapjack-cream/80 p-3 text-xs text-flapjack-ink/80">{JSON.stringify(
								hit,
								null,
								2
							)}</pre>
					{/each}
				</div>
			{:else}
				<p class="text-sm text-flapjack-ink/60">No results found.</p>
			{/if}
		</div>
	{/if}
</div>

<ConnectYourAppCard {index} />

{#if indexProvisioned}
	<div
		class="mb-6 rounded-lg border border-flapjack-ink/15 bg-white p-5 shadow"
		data-testid="overview-navigation"
	>
		<h2 class="mb-3 text-base font-medium text-flapjack-ink">Continue setup</h2>
		<div class="flex flex-wrap gap-3 text-sm">
			<!-- eslint-disable svelte/no-navigation-without-resolve -->
			<a
				href={settingsTabHref}
				class="rounded-md border border-flapjack-ink/20 px-3 py-2 text-flapjack-ink/80 hover:bg-flapjack-cream/80"
				>Configure Settings</a
			>
			<a
				href={analyticsTabHref}
				class="rounded-md border border-flapjack-ink/20 px-3 py-2 text-flapjack-ink/80 hover:bg-flapjack-cream/80"
				>View Analytics</a
			>
			<a
				href={documentsTabHref}
				class="rounded-md border border-flapjack-ink/20 px-3 py-2 text-flapjack-ink/80 hover:bg-flapjack-cream/80"
				>Manage Documents</a
			>
			<!-- eslint-enable svelte/no-navigation-without-resolve -->
		</div>
	</div>
{/if}

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
