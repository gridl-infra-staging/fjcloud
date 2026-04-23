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
		return JSON.stringify(hit);
	}
</script>

		<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="recommendations-section" data-index={index.name}>
			<h2 class="mb-4 text-lg font-medium text-gray-900">Recommendations</h2>
			<p class="mb-4 text-sm text-gray-600">
				Request batched recommendations for this index.
			</p>

			{#if recommendationsError}
				<div class="mb-4 rounded-md bg-red-50 p-3 text-sm text-red-700">{recommendationsError}</div>
			{/if}

			<div class="mb-6 rounded-md border border-gray-200 p-4">
				<form method="POST" action="?/recommend" use:enhance>
					<label for="recommendations-request-json" class="mb-2 block text-sm font-medium text-gray-700"
						>Recommendations JSON</label
					>
					<textarea
						id="recommendations-request-json"
						name="request"
						bind:value={requestText}
						rows="14"
						class="mb-4 w-full rounded-md border border-gray-300 p-3 font-mono text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
					></textarea>
					<button
						type="submit"
						class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
					>
						Get Recommendations
					</button>
				</form>
			</div>

			{#if recommendationsResponse?.results?.length}
				<div class="space-y-4">
					{#each recommendationsResponse.results as result, resultIndex (resultIndex)}
						<div class="rounded-md border border-gray-200 bg-gray-50 p-4">
							<p class="mb-2 text-sm font-medium text-gray-900">
								Request #{resultIndex + 1} · {result.processingTimeMS} ms
							</p>
							{#if result.hits.length === 0}
								<p class="text-sm text-gray-500">No hits returned.</p>
							{:else}
								<ul class="list-inside list-disc space-y-1 text-sm text-gray-700">
									{#each result.hits as hit, hitIndex (hitIndex)}
										<li>{hitLabel(hit)}</li>
									{/each}
								</ul>
							{/if}
						</div>
					{/each}
				</div>
			{:else}
				<p class="text-sm text-gray-500">No recommendations requested yet.</p>
			{/if}
		</div>
