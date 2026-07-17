<script lang="ts">
	import { enhance } from '$app/forms';
	import { invalidateAll } from '$app/navigation';
	import type { BrowseObjectsResponse, Index } from '$lib/api/types';
	import InstantSearch from '$lib/components/InstantSearch.svelte';
	import { INDEX_DETAIL_TAB_PANEL_TEST_IDS } from '../index_detail_tabs';
	import type { RuleListPayload } from './rule_payload';

	let {
		index,
		rawIndexName = index.name,
		settings = null,
		documents,
		restoreError = '',
		onRequestDocumentsTab,
		rules = null
	}: {
		index: Index;
		rawIndexName?: string;
		settings?: Record<string, unknown> | null;
		documents?: BrowseObjectsResponse;
		restoreError?: string;
		onRequestDocumentsTab?: () => void;
		rules?: RuleListPayload | null;
	} = $props();

	let restoreSubmitting = $state(false);
	let statusRefreshing = $state(false);
	let statusRefreshError = $state('');

	async function refreshLifecycleStatus(): Promise<void> {
		statusRefreshError = '';
		statusRefreshing = true;
		try {
			await invalidateAll();
		} catch {
			statusRefreshError = 'Could not refresh restore status. Try again.';
		} finally {
			statusRefreshing = false;
		}
	}

	function normalizeConfiguredFacet(attribute: string): string {
		const wrapperMatch = attribute.match(/^(?:searchable|filterOnly)\((.+)\)$/);
		return wrapperMatch?.[1] ?? attribute;
	}

	const configuredFacets = $derived.by((): string[] | null => {
		if (settings === null) return null;
		const rawFacets = settings.attributesForFaceting;
		if (!Array.isArray(rawFacets)) return [];
		return rawFacets
			.filter((attribute): attribute is string => typeof attribute === 'string')
			.map(normalizeConfiguredFacet);
	});

	// First rule match per objectID wins (API's natural ordering).
	const pinnedPositions = $derived.by(() => {
		const entries: Array<[string, number]> = [];
		for (const rule of rules?.hits ?? []) {
			for (const entry of rule.consequence?.promote ?? []) {
				const objectID = typeof entry.objectID === 'string' ? entry.objectID : null;
				const position = typeof entry.position === 'number' ? entry.position : NaN;
				if (objectID && position >= 1 && !entries.some(([id]) => id === objectID)) {
					entries.push([objectID, position]);
				}
			}
		}
		return new Map(entries);
	});
</script>

<section
	data-testid={INDEX_DETAIL_TAB_PANEL_TEST_IDS.search}
	data-documents-callback={onRequestDocumentsTab ? 'provided' : 'missing'}
>
	<h2 class="mb-4 text-lg font-semibold text-flapjack-ink">Search</h2>

	{#if index.tier === 'cold'}
		<div class="rounded-lg border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-6 text-center">
			<p class="text-sm font-medium text-flapjack-ink">
				This index is in cold storage to reduce storage costs.
			</p>
			<p class="mt-1 text-sm text-flapjack-ink/75">
				Restore it to search and manage documents again.
			</p>
			{#if restoreError}
				<p class="mt-3 text-sm text-flapjack-rose" role="alert">{restoreError}</p>
			{/if}
			<form
				method="POST"
				action="?/restoreIndex"
				class="mt-4"
				use:enhance={() => {
					restoreSubmitting = true;
					return async ({ update }) => {
						// Default action handling applies any visible error and reloads the
						// index, whose tier becomes `restoring` after a successful request.
						try {
							await update();
						} finally {
							restoreSubmitting = false;
						}
					};
				}}
			>
				<button
					type="submit"
					disabled={restoreSubmitting}
					class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-semibold text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-60"
				>
					{restoreSubmitting ? 'Starting restore…' : 'Restore index'}
				</button>
			</form>
		</div>
	{:else if index.tier === 'restoring'}
		<div class="rounded-lg border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-6 text-center">
			<p class="text-sm font-medium text-flapjack-ink">
				Restoring this index from cold storage. Search will return when it is active.
			</p>
			<p class="mt-1 text-sm text-flapjack-ink/75">Restore time depends on the index size.</p>
			{#if statusRefreshError}
				<p class="mt-3 text-sm text-flapjack-rose" role="alert">{statusRefreshError}</p>
			{/if}
			<button
				type="button"
				disabled={statusRefreshing}
				class="mt-4 rounded-md border border-flapjack-rose px-4 py-2 text-sm font-semibold text-flapjack-rose hover:border-flapjack-plum hover:text-flapjack-plum disabled:cursor-not-allowed disabled:opacity-60"
				onclick={refreshLifecycleStatus}
			>
				{statusRefreshing ? 'Refreshing…' : 'Refresh status'}
			</button>
		</div>
	{:else if !index.endpoint}
		<div class="rounded-lg border border-flapjack-ink/20 bg-flapjack-cream/80 p-6 text-center">
			<p class="text-sm text-flapjack-ink/70">
				Endpoint not available yet. The index is still being provisioned.
			</p>
		</div>
	{:else}
		<!-- InstantSearch owns merchMode state for the header toggle and card controls. -->
		<InstantSearch
			indexName={rawIndexName}
			{configuredFacets}
			documentSample={documents?.hits ?? []}
			{pinnedPositions}
			{onRequestDocumentsTab}
		/>
	{/if}
</section>
