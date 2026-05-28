<script lang="ts">
	import DocumentCard from '../DocumentCard.svelte';

	type SearchHit = Record<string, unknown>;

	let {
		nbHits = 0,
		processingTimeMS = 0,
		hits = [],
		page = 1,
		totalPages = 1,
		loading = false,
		onPageChange = () => {},
		onHitClick = () => {}
	}: {
		nbHits?: number;
		processingTimeMS?: number;
		hits?: SearchHit[];
		page?: number;
		totalPages?: number;
		loading?: boolean;
		onPageChange?: (nextPage: number) => void;
		onHitClick?: (hit: SearchHit, position: number) => void;
	} = $props();

	const previousDisabled = $derived(page <= 1 || loading);
	const nextDisabled = $derived(page >= totalPages || loading);
</script>

<section class="space-y-3" data-testid="search-preview-results">
	<div class="flex items-center justify-between">
		<p class="text-sm text-flapjack-ink">{nbHits} hits · {processingTimeMS}ms</p>
		<div class="flex gap-2">
			<button
				type="button"
				class="rounded border border-flapjack-ink/20 px-2 py-1 text-xs disabled:opacity-50"
				aria-label="Previous page"
				disabled={previousDisabled}
				onclick={() => onPageChange(page - 1)}
			>
				Prev
			</button>
			<button
				type="button"
				class="rounded border border-flapjack-ink/20 px-2 py-1 text-xs disabled:opacity-50"
				aria-label="Next page"
				disabled={nextDisabled}
				onclick={() => onPageChange(page + 1)}
			>
				Next
			</button>
		</div>
	</div>

	{#if loading}
		<div
			data-testid="search-preview-results-skeleton"
			class="rounded border border-flapjack-ink/15 bg-flapjack-cream/70 p-4 text-sm text-flapjack-ink/70"
		>
			Loading preview results...
		</div>
	{:else if hits.length === 0}
		<p class="text-sm text-flapjack-ink/70">No preview hits yet.</p>
	{:else}
		<div class="space-y-2">
			{#each hits as hit, index (String(hit.objectID ?? index))}
				<div
					role="button"
					tabindex="0"
					aria-label={`Open hit ${String(hit.objectID ?? index)}`}
					onclick={() => onHitClick(hit, index + 1)}
					onkeydown={(event) => {
						if (event.key === 'Enter' || event.key === ' ') {
							event.preventDefault();
							onHitClick(hit, index + 1);
						}
					}}
				>
					<DocumentCard {hit} />
				</div>
			{/each}
		</div>
	{/if}
</section>
