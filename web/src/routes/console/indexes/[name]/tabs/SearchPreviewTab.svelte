<script lang="ts">
	import { enhance } from '$app/forms';
	import type { Index } from '$lib/api/types';
	import InstantSearch from '$lib/components/InstantSearch.svelte';

	let {
		index,
		previewKey,
		previewKeyError,
		previewIndexName
	}: {
		index: Index;
		previewKey: string;
		previewKeyError: string;
		previewIndexName: string;
	} = $props();

	const unavailable = $derived(index.tier === 'cold' || index.tier === 'restoring');
</script>

<section data-testid="search-preview-section">
	<h2 class="mb-4 text-lg font-semibold text-flapjack-ink">Search Preview</h2>

	{#if unavailable}
		<div class="rounded-lg border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-6 text-center">
			<p class="text-sm text-flapjack-ink/80">
				Search preview is not available while the index is <strong>{index.tier}</strong>. Please
				wait for the index to become active.
			</p>
		</div>
	{:else if !index.endpoint}
		<div class="rounded-lg border border-flapjack-ink/20 bg-flapjack-cream/80 p-6 text-center">
			<p class="text-sm text-flapjack-ink/70">
				Endpoint not available yet. The index is still being provisioned.
			</p>
		</div>
	{:else if !previewKey}
		<div class="rounded-lg border border-flapjack-ink/20 bg-white p-6">
			<p class="mb-4 text-sm text-flapjack-ink/70">
				Generate a temporary search key to preview live search results from this index.
			</p>
			{#if previewKeyError}
				<p class="mb-4 text-sm text-flapjack-plum">{previewKeyError}</p>
			{/if}
			<form method="POST" action="?/createPreviewKey" use:enhance>
				<button
					type="submit"
					class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
				>
					Generate Preview Key
				</button>
			</form>
		</div>
	{:else}
		<InstantSearch endpoint={index.endpoint} apiKey={previewKey} indexName={previewIndexName} />
	{/if}
</section>
