<script lang="ts">
	import { enhance } from '$app/forms';
	import { resolve } from '$app/paths';
	import { copyToClipboard } from '$lib/clipboard';
	import { formatBytes, formatNumber, statusLabel } from '$lib/format';
	import type { Index, IndexReplicaSummary, InternalRegion, SearchResult } from '$lib/api/types';
	import {
		buildSnippetContext,
		buildFrameworkSnippets,
		CORS_ALLOWED_ORIGINS,
		type FrameworkId
	} from './connect-your-app-snippets';

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
		replicaCreated
	}: Props = $props();

	let showAddReplica = $state(false);
	let selectedReplicaRegion = $state('');
	let deleteConfirmName = $state('');
	let showDeleteConfirm = $state(false);
	let activeSnippetTab = $state<FrameworkId>('react');

	const snippetContext = $derived(
		index.endpoint ? buildSnippetContext(index.endpoint, index.name) : null
	);
	const frameworkSnippets = $derived(snippetContext ? buildFrameworkSnippets(snippetContext) : []);
	const activeSnippet = $derived(frameworkSnippets.find((s) => s.id === activeSnippetTab) ?? null);
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

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="connect-your-app">
	<h2 class="mb-2 text-lg font-medium text-flapjack-ink">Connect Your App</h2>
	<p class="mb-3 text-sm text-flapjack-ink/70">
		Use the code snippets below to connect your application to this index. You'll need an API key —
		manage your keys on the
		<a href={resolve('/console/api-keys')} class="font-medium text-flapjack-rose hover:underline"
			>API Keys</a
		> page.
	</p>

	{#if snippetContext && frameworkSnippets.length > 0}
		<div
			class="mb-3 inline-flex rounded-lg border border-flapjack-ink/20 bg-flapjack-cream/80 p-1"
			role="tablist"
			aria-label="Framework snippets"
		>
			{#each frameworkSnippets as fw (fw.id)}
				<button
					type="button"
					role="tab"
					aria-selected={activeSnippetTab === fw.id}
					onclick={() => {
						activeSnippetTab = fw.id;
					}}
					class="rounded-md px-3 py-1.5 text-sm font-medium {activeSnippetTab === fw.id
						? 'bg-white shadow text-flapjack-ink'
						: 'text-flapjack-ink/70 hover:text-flapjack-ink'}"
				>
					{fw.label}
				</button>
			{/each}
		</div>

		{#if activeSnippet}
			<div data-testid="snippet-panel">
				<pre
					class="mb-3 overflow-x-auto rounded-md bg-flapjack-ink p-4 text-sm text-flapjack-cream">{activeSnippet.clientSetup}</pre>
				<pre
					class="overflow-x-auto rounded-md bg-flapjack-ink p-4 text-sm text-flapjack-cream">{activeSnippet.instantSearchSetup}</pre>
			</div>
		{/if}
	{:else}
		<p class="text-sm text-flapjack-ink/50">
			Endpoint not ready — snippets will appear once your index is provisioned.
		</p>
	{/if}

	<div class="mt-4 rounded-md border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-3">
		<p class="text-sm font-medium text-flapjack-ink/80">CORS Limitation</p>
		<p class="mt-1 text-sm text-flapjack-plum">
			Browser requests are currently restricted to the following origins:
			{#each CORS_ALLOWED_ORIGINS as origin, i (origin)}<code
					class="rounded bg-flapjack-yellow/30 px-1">{origin}</code
				>{#if i < CORS_ALLOWED_ORIGINS.length - 1}
					and
				{/if}{/each}. Server-side requests (e.g. from your backend) are not affected by this
			restriction.
		</p>
	</div>
</div>

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
