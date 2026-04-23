<script lang="ts">
	import { browser } from '$app/environment';
	import { enhance } from '$app/forms';
	import { resolve } from '$app/paths';
	import { formatBytes, formatNumber, statusLabel } from '$lib/format';
	import type { Index, IndexReplicaSummary, InternalRegion, SearchResult } from '$lib/api/types';
	import { buildSnippetContext, buildFrameworkSnippets, CORS_ALLOWED_ORIGINS, type FrameworkId } from './connect-your-app-snippets';

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
	const frameworkSnippets = $derived(
		snippetContext ? buildFrameworkSnippets(snippetContext) : []
	);
	const activeSnippet = $derived(
		frameworkSnippets.find((s) => s.id === activeSnippetTab) ?? null
	);

	async function copyToClipboard(text: string, buttonId: string) {
		if (!browser) return;
		try {
			await navigator.clipboard.writeText(text);
			const buttonElement = document.getElementById(buttonId);
			if (buttonElement) {
				const originalText = buttonElement.textContent;
				buttonElement.textContent = 'Copied!';
				setTimeout(() => {
					buttonElement.textContent = originalText;
				}, 2000);
			}
		} catch {
			// Clipboard API not available.
		}
	}
</script>

		<div
			class="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4"
			data-testid="stats-section"
			data-region-count={regions.length}
		>
			<div class="rounded-lg bg-white p-4 shadow">
				<p class="text-sm font-medium text-gray-500">Entries</p>
				<p class="mt-1 text-2xl font-semibold text-gray-900" data-testid="stat-entries-value">{formatNumber(index.entries)}</p>
			</div>
			<div class="rounded-lg bg-white p-4 shadow">
				<p class="text-sm font-medium text-gray-500">Data Size</p>
				<p class="mt-1 text-2xl font-semibold text-gray-900" data-testid="stat-data-size-value">{formatBytes(index.data_size_bytes)}</p>
			</div>
			<div class="rounded-lg bg-white p-4 shadow">
				<p class="text-sm font-medium text-gray-500">Region</p>
				<p class="mt-1 text-2xl font-semibold text-gray-900" data-testid="stat-region-value">{index.region}</p>
			</div>
			<div class="rounded-lg bg-white p-4 shadow">
				<p class="text-sm font-medium text-gray-500">Endpoint</p>
				{#if index.endpoint}
					<div class="mt-1 flex items-center gap-2">
						<code class="truncate text-sm text-gray-900">{index.endpoint}</code>
						<button
							id="copy-endpoint"
							type="button"
							onclick={() => copyToClipboard(index.endpoint ?? '', 'copy-endpoint')}
							class="shrink-0 rounded border border-gray-300 px-2 py-0.5 text-xs text-gray-600 hover:bg-gray-50"
						>
							Copy
						</button>
					</div>
				{:else}
					<p class="mt-1 text-sm text-gray-400">Preparing...</p>
				{/if}
			</div>
		</div>

		<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="search-widget">
			<h2 class="mb-4 text-lg font-medium text-gray-900">Test Search</h2>
			<form method="POST" action="?/search" use:enhance class="flex gap-3">
				<input
					type="text"
					name="query"
					value={searchQuery}
					placeholder="Search your index..."
					class="flex-1 rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
				/>
				<button
					type="submit"
					class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
				>
					Search
				</button>
			</form>

			{#if searchError}
				<div class="mt-3 rounded-md bg-red-50 p-3 text-sm text-red-700">{searchError}</div>
			{/if}

			{#if searchResult}
				<div class="mt-4" data-testid="search-results">
					<div class="mb-2 flex items-center gap-4 text-sm text-gray-500">
						<span>{searchResult.nbHits} hit{searchResult.nbHits !== 1 ? 's' : ''}</span>
						<span>{searchResult.processingTimeMs}ms</span>
					</div>
					{#if searchResult.hits.length > 0}
						<div class="space-y-2">
							{#each searchResult.hits as hit, idx (idx)}
								<pre class="overflow-x-auto rounded-md bg-gray-50 p-3 text-xs text-gray-700">{JSON.stringify(hit, null, 2)}</pre>
							{/each}
						</div>
					{:else}
						<p class="text-sm text-gray-500">No results found.</p>
					{/if}
				</div>
			{/if}
		</div>

		<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="connect-your-app">
			<h2 class="mb-2 text-lg font-medium text-gray-900">Connect Your App</h2>
			<p class="mb-3 text-sm text-gray-600">
				Use the code snippets below to connect your application to this index.
				You'll need an API key — manage your keys on the
				<a href={resolve('/dashboard/api-keys')} class="font-medium text-blue-600 hover:underline">API Keys</a> page.
			</p>

			{#if snippetContext && frameworkSnippets.length > 0}
				<div class="mb-3 inline-flex rounded-lg border border-gray-200 bg-gray-50 p-1" role="tablist" aria-label="Framework snippets">
					{#each frameworkSnippets as fw (fw.id)}
						<button
							type="button"
							role="tab"
							aria-selected={activeSnippetTab === fw.id}
							onclick={() => { activeSnippetTab = fw.id; }}
							class="rounded-md px-3 py-1.5 text-sm font-medium {activeSnippetTab === fw.id ? 'bg-white shadow text-gray-900' : 'text-gray-600 hover:text-gray-900'}"
						>
							{fw.label}
						</button>
					{/each}
				</div>

				{#if activeSnippet}
					<div data-testid="snippet-panel">
						<pre class="mb-3 overflow-x-auto rounded-md bg-gray-900 p-4 text-sm text-gray-100">{activeSnippet.clientSetup}</pre>
						<pre class="overflow-x-auto rounded-md bg-gray-900 p-4 text-sm text-gray-100">{activeSnippet.instantSearchSetup}</pre>
					</div>
				{/if}
			{:else}
				<p class="text-sm text-gray-400">Endpoint not ready — snippets will appear once your index is provisioned.</p>
			{/if}

			<div class="mt-4 rounded-md border border-amber-200 bg-amber-50 p-3">
				<p class="text-sm font-medium text-amber-800">CORS Limitation</p>
				<p class="mt-1 text-sm text-amber-700">
					Browser requests are currently restricted to the following origins:
					{#each CORS_ALLOWED_ORIGINS as origin, i (origin)}<code class="rounded bg-amber-100 px-1">{origin}</code>{#if i < CORS_ALLOWED_ORIGINS.length - 1} and {/if}{/each}.
					Server-side requests (e.g. from your backend) are not affected by this restriction.
				</p>
			</div>
		</div>

		<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="replicas-section">
			<div class="mb-4 flex items-center justify-between">
				<h2 class="text-lg font-medium text-gray-900">Read Replicas</h2>
				{#if availableReplicaRegions.length > 0}
					<button
						type="button"
						onclick={() => {
							showAddReplica = !showAddReplica;
						}}
						class="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700"
					>
						Add Replica
					</button>
				{/if}
			</div>

			{#if replicaError}
				<div class="mb-4 rounded-md bg-red-50 p-3 text-sm text-red-700">{replicaError}</div>
			{/if}

			{#if replicaCreated}
				<div class="mb-4 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
					Replica created. It will begin syncing shortly.
				</div>
			{/if}

			{#if showAddReplica}
				<div class="mb-4 rounded-md border border-blue-200 bg-blue-50 p-4">
					<form method="POST" action="?/createReplica" use:enhance>
						<label for="replica-region" class="mb-2 block text-sm font-medium text-gray-700">Target region</label>
						<div class="flex gap-3">
							<select
								id="replica-region"
								name="region"
								bind:value={selectedReplicaRegion}
								class="flex-1 rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
							>
								<option value="" disabled>Select a region...</option>
									{#each availableReplicaRegions as region (region.id)}
									<option value={region.id}>{region.display_name} ({region.id})</option>
								{/each}
							</select>
							<button
								type="submit"
								disabled={!selectedReplicaRegion}
								class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50"
							>
								Create
							</button>
							<button
								type="button"
								onclick={() => {
									showAddReplica = false;
									selectedReplicaRegion = '';
								}}
								class="rounded-md border border-gray-300 px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50"
							>
								Cancel
							</button>
						</div>
					</form>
				</div>
			{/if}

			{#if replicas.length === 0}
				<p class="text-sm text-gray-500">No read replicas. Add a replica in another region for lower-latency reads.</p>
			{:else}
				<div class="overflow-hidden rounded-lg border">
					<table class="w-full text-left text-sm">
						<thead class="border-b bg-gray-50 text-xs font-medium uppercase text-gray-500">
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
									<td class="px-4 py-2 text-gray-900">{replica.replica_region}</td>
									<td class="px-4 py-2">
										<span
											class="inline-flex rounded-full px-2 py-0.5 text-xs font-medium
											{replica.status === 'active'
												? 'bg-green-100 text-green-800'
												: replica.status === 'syncing' || replica.status === 'provisioning'
													? 'bg-yellow-100 text-yellow-800'
													: replica.status === 'failed'
														? 'bg-red-100 text-red-800'
														: 'bg-gray-100 text-gray-800'}"
										>
											{statusLabel(replica.status)}
										</span>
									</td>
									<td class="px-4 py-2 text-gray-600">{replica.lag_ops}</td>
									<td class="px-4 py-2 text-right">
										<form method="POST" action="?/deleteReplica" use:enhance>
											<input type="hidden" name="replica_id" value={replica.id} />
											<button
												type="submit"
												class="rounded border border-red-300 px-3 py-1 text-xs text-red-700 hover:bg-red-50"
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

		<div class="rounded-lg border border-red-200 bg-white p-6 shadow" data-testid="danger-zone">
			<h2 class="mb-2 text-lg font-medium text-red-700">Danger Zone</h2>
			<p class="mb-4 text-sm text-gray-600">Deleting an index is permanent. All data in the index will be lost.</p>

			{#if deleteError}
				<div class="mb-4 rounded-md bg-red-50 p-3 text-sm text-red-700">{deleteError}</div>
			{/if}

			{#if showDeleteConfirm}
				<form method="POST" action="?/delete" use:enhance>
					<p class="mb-2 text-sm text-gray-700">Type <strong>{index.name}</strong> to confirm:</p>
					<input
						type="text"
						bind:value={deleteConfirmName}
						placeholder={index.name}
						class="mb-3 w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-red-500 focus:ring-1 focus:ring-red-500"
					/>
					<div class="flex gap-3">
						<button
							type="submit"
							disabled={deleteConfirmName !== index.name}
							class="rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:cursor-not-allowed disabled:opacity-50"
						>
							Permanently Delete
						</button>
						<button
							type="button"
							onclick={() => {
								showDeleteConfirm = false;
								deleteConfirmName = '';
							}}
							class="rounded-md border border-gray-300 px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50"
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
					class="rounded-md border border-red-300 px-4 py-2 text-sm font-medium text-red-700 hover:bg-red-50"
				>
					Delete this index
				</button>
			{/if}
		</div>
