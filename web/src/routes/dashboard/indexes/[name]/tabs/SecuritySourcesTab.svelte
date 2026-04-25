<script lang="ts">
	import { enhance } from '$app/forms';
	import type { Index, SecuritySource, SecuritySourcesResponse } from '$lib/api/types';

	type Props = {
		index: Index;
		securitySources: SecuritySourcesResponse;
		securitySourceAppendError: string;
		securitySourceDeleteError: string;
		securitySourceAppended: boolean;
		securitySourceDeleted: boolean;
	};

	let {
		index,
		securitySources,
		securitySourceAppendError,
		securitySourceDeleteError,
		securitySourceAppended,
		securitySourceDeleted
	}: Props = $props();

	let sourceDraft = $state('');
	let descriptionDraft = $state('');

	const sources: SecuritySource[] = $derived(securitySources.sources ?? []);
	const hasSources: boolean = $derived(sources.length > 0);
</script>

<div class="space-y-6" data-testid="security-sources-section" data-index={index.name}>
	<div class="rounded-lg bg-white p-6 shadow">
		<h2 class="mb-2 text-lg font-medium text-gray-900">Security Sources</h2>
		<p class="mb-4 text-sm text-gray-600">
			Manage IP-based security sources (CIDR ranges) that control access to this index.
		</p>

		{#if securitySourceAppended}
			<div class="mb-3 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
				Security source added.
			</div>
		{/if}
		{#if securitySourceDeleted}
			<div class="mb-3 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
				Security source deleted.
			</div>
		{/if}
		{#if securitySourceAppendError}
			<div class="mb-3 rounded-md bg-red-50 p-3 text-sm text-red-700">
				{securitySourceAppendError}
			</div>
		{/if}
		{#if securitySourceDeleteError}
			<div class="mb-3 rounded-md bg-red-50 p-3 text-sm text-red-700">
				{securitySourceDeleteError}
			</div>
		{/if}
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-gray-900">Add Source</h3>
		<form
			method="POST"
			action="?/appendSecuritySource"
			use:enhance
			class="grid gap-3 md:grid-cols-3"
		>
			<div>
				<label for="security-source-input" class="mb-1 block text-sm font-medium text-gray-700">
					Source
				</label>
				<input
					id="security-source-input"
					aria-label="Source"
					name="source"
					type="text"
					bind:value={sourceDraft}
					placeholder="e.g. 192.168.1.0/24"
					class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
				/>
			</div>
			<div>
				<label
					for="security-source-description"
					class="mb-1 block text-sm font-medium text-gray-700"
				>
					Description
				</label>
				<input
					id="security-source-description"
					aria-label="Description"
					name="description"
					type="text"
					bind:value={descriptionDraft}
					placeholder="e.g. Office network"
					class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
				/>
			</div>
			<div class="flex items-end">
				<button
					type="submit"
					disabled={sourceDraft.trim().length === 0}
					class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
				>
					Add Source
				</button>
			</div>
		</form>
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-gray-900">Sources</h3>
		{#if hasSources}
			<div class="space-y-3">
				{#each sources as entry (entry.source)}
					<div class="flex items-center justify-between rounded-md border border-gray-200 p-3">
						<div>
							<p class="font-mono text-sm text-gray-900">{entry.source}</p>
							{#if entry.description}
								<p class="text-xs text-gray-500">{entry.description}</p>
							{/if}
						</div>
						<form method="POST" action="?/deleteSecuritySource" use:enhance>
							<input type="hidden" name="source" value={entry.source} />
							<button
								type="submit"
								aria-label={`Delete security source ${entry.source}`}
								class="rounded border border-red-300 px-3 py-1 text-xs text-red-700 hover:bg-red-50"
							>
								Delete
							</button>
						</form>
					</div>
				{/each}
			</div>
		{:else}
			<p class="text-sm text-gray-500">No security sources configured</p>
		{/if}
	</div>
</div>
