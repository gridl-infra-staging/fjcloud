<script lang="ts">
	import { enhance } from '$app/forms';
	import type { Index, RecommendationsBatchResponse } from '$lib/api/types';

	type Props = {
		index: Index;
		recommendationsResponse: RecommendationsBatchResponse | null;
		recommendationsError: string;
	};

	let { index, recommendationsResponse, recommendationsError }: Props = $props();

	const defaultRequestText = $derived(
		JSON.stringify(
			{
				requests: [
					{
						indexName: index.name,
						model: 'trending-items',
						threshold: 0,
						maxRecommendations: 5
					}
				]
			},
			null,
			2
		)
	);
	let requestText = $state('');
	let lastHydratedIndexName = $state('');

	$effect(() => {
		if (index.name !== lastHydratedIndexName) {
			requestText = defaultRequestText;
			lastHydratedIndexName = index.name;
			return;
		}

		if (requestText.trim().length === 0) {
			requestText = defaultRequestText;
		}
	});

	function hitLabel(hit: Record<string, unknown>): string {
		const objectID = hit.objectID;
		if (typeof objectID === 'string' && objectID.length > 0) {
			return objectID;
		}

		const facetName =
			(typeof hit.facet_name === 'string' && hit.facet_name.length > 0
				? hit.facet_name
				: null) ??
			(typeof hit.facetName === 'string' && hit.facetName.length > 0 ? hit.facetName : null);
		const facetValue =
			(typeof hit.facet_value === 'string' && hit.facet_value.length > 0
				? hit.facet_value
				: null) ??
			(typeof hit.facetValue === 'string' && hit.facetValue.length > 0
				? hit.facetValue
				: null);
		if (facetName && facetValue) {
			return `${facetName}: ${facetValue}`;
		}

		return JSON.stringify(hit);
	}
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid="recommendations-section"
	data-index={index.name}
>
	<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Recommendations</h2>
	<p class="mb-4 text-sm text-flapjack-ink/70">Request batched recommendations for this index.</p>

	{#if recommendationsError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{recommendationsError}
		</div>
	{/if}

	<div class="mb-6 rounded-md border border-flapjack-ink/20 p-4">
		<form method="POST" action="?/recommend" use:enhance>
			<label
				for="recommendations-request-json"
				class="mb-2 block text-sm font-medium text-flapjack-ink/80">Recommendations JSON</label
			>
			<textarea
				id="recommendations-request-json"
				name="request"
				bind:value={requestText}
				rows="14"
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-3 font-mono text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			></textarea>
			<button
				type="submit"
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
			>
				Get Recommendations
			</button>
		</form>
	</div>

	{#if recommendationsResponse?.results?.length}
		<div class="space-y-4">
			{#each recommendationsResponse.results as result, resultIndex (resultIndex)}
				<div class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4">
					<p class="mb-2 text-sm font-medium text-flapjack-ink">
						Request #{resultIndex + 1} · {result.processingTimeMS} ms
					</p>
					{#if result.hits.length === 0}
						<p class="text-sm text-flapjack-ink/60">No hits returned.</p>
					{:else}
						<ul class="list-inside list-disc space-y-1 text-sm text-flapjack-ink/80">
							{#each result.hits as hit, hitIndex (hitIndex)}
								<li>{hitLabel(hit)}</li>
							{/each}
						</ul>
					{/if}
				</div>
			{/each}
		</div>
	{:else}
		<p class="text-sm text-flapjack-ink/60">No recommendations requested yet.</p>
	{/if}
</div>
