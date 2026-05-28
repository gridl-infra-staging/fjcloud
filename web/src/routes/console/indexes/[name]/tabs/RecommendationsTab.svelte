<script lang="ts">
	import { applyAction, enhance } from '$app/forms';
	import type { SubmitFunction } from '@sveltejs/kit';
	import type { Index, RecommendationsBatchResponse } from '$lib/api/types';
	import EditorDialog from '$lib/components/EditorDialog.svelte';
	import {
		defaultRecommendationConfig,
		recommendationConfigEditorSchema,
		recommendationConfigFromDialogValues,
		serializeRecommendationsBatchRequest,
		type RecommendationConfig
	} from '$lib/recommendations/config';
	import { metadataForModel, RECOMMENDATION_MODELS } from '$lib/recommendations/model_metadata';

	type Props = {
		index: Index;
		recommendationsResponse: RecommendationsBatchResponse | null;
		recommendationsError: string;
	};

	let { index, recommendationsResponse, recommendationsError }: Props = $props();

	let recommendationConfig = $state<RecommendationConfig>(defaultRecommendationConfig());
	let editConfigurationDialogOpen = $state(false);
	let requestGen = $state(0);
	let previousRequestPayload: string | null = null;

	const selectedModelMetadata = $derived(metadataForModel(recommendationConfig.model));
	const configurationEditorSchema = recommendationConfigEditorSchema();
	const configurationEditorInitialValue = $derived({
		model: recommendationConfig.model,
		objectID: recommendationConfig.objectID,
		facetName: recommendationConfig.facetName,
		facetValue: recommendationConfig.facetValue,
		threshold: recommendationConfig.threshold,
		maxRecommendations: recommendationConfig.maxRecommendations
	});

	function hasRequiredText(value: string): boolean {
		return value.trim().length > 0;
	}

	function recommendationConfigIsIncomplete(config: RecommendationConfig): boolean {
		if (selectedModelMetadata.requiresObjectID && !hasRequiredText(config.objectID)) {
			return true;
		}

		if (selectedModelMetadata.requiresFacetName) {
			return !hasRequiredText(config.facetName) || !hasRequiredText(config.facetValue);
		}

		return false;
	}

	function hitValue(
		hit: Record<string, unknown>,
		primaryKey: string,
		fallbackKey: string
	): string | null {
		const primaryValue = hit[primaryKey];
		if (typeof primaryValue === 'string' && primaryValue.length > 0) {
			return primaryValue;
		}

		const fallbackValue = hit[fallbackKey];
		if (typeof fallbackValue === 'string' && fallbackValue.length > 0) {
			return fallbackValue;
		}

		return null;
	}

	const submitDisabled = $derived(recommendationConfigIsIncomplete(recommendationConfig));
	const requestPayload = $derived(
		serializeRecommendationsBatchRequest(index.name, recommendationConfig)
	);

	const applyLatestRecommendationResult: SubmitFunction = () => {
		requestGen += 1;
		const submitGeneration = requestGen;
		return async ({ result }) => {
			if (submitGeneration !== requestGen) {
				return;
			}
			await applyAction(result);
		};
	};

	$effect(() => {
		const currentRequestPayload = requestPayload;
		const requestChanged =
			previousRequestPayload !== null && previousRequestPayload !== currentRequestPayload;
		previousRequestPayload = currentRequestPayload;
		if (requestChanged) {
			requestGen += 1;
		}
	});

	function openEditConfigurationDialog(): void {
		editConfigurationDialogOpen = true;
	}

	function closeEditConfigurationDialog(): void {
		editConfigurationDialogOpen = false;
	}

	async function saveConfigurationEdits(values: Record<string, unknown>): Promise<void> {
		recommendationConfig = recommendationConfigFromDialogValues(values, recommendationConfig);
		closeEditConfigurationDialog();
	}

	function hitLabel(hit: Record<string, unknown>): string {
		const objectID = hitValue(hit, 'objectID', 'objectID');
		if (objectID) {
			return objectID;
		}

		const facetName =
			(typeof hit.facet_name === 'string' && hit.facet_name.length > 0 ? hit.facet_name : null) ??
			(typeof hit.facetName === 'string' && hit.facetName.length > 0 ? hit.facetName : null);
		const facetValue =
			(typeof hit.facet_value === 'string' && hit.facet_value.length > 0
				? hit.facet_value
				: null) ??
			(typeof hit.facetValue === 'string' && hit.facetValue.length > 0 ? hit.facetValue : null);
		if (facetName && facetValue) {
			return `${facetName}: ${facetValue}`;
		}

		return JSON.stringify(hit);
	}

	function hasAnyHits(results: RecommendationsBatchResponse['results']): boolean {
		return results.some((result) => result.hits.length > 0);
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
		<div role="alert" class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{recommendationsError}
		</div>
	{/if}

	<div class="mb-6 rounded-md border border-flapjack-ink/20 p-4">
		<div class="mb-4 flex items-center justify-end">
			<button
				type="button"
				onclick={openEditConfigurationDialog}
				class="rounded-md border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
			>
				Edit Configuration
			</button>
		</div>

		<form method="POST" action="?/recommend" use:enhance={applyLatestRecommendationResult}>
			<input type="hidden" name="request" value={requestPayload} />

			<label for="recommendations-model" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
				>Model</label
			>
			<select
				id="recommendations-model"
				bind:value={recommendationConfig.model}
				data-testid="recommendations-model-select"
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			>
				{#each RECOMMENDATION_MODELS as model (model.id)}
					<option value={model.id}>{model.label}</option>
				{/each}
			</select>

			{#if selectedModelMetadata.requiresObjectID}
				<label
					for="recommendations-object-id"
					class="mb-2 block text-sm font-medium text-flapjack-ink/80">Object ID</label
				>
				<input
					id="recommendations-object-id"
					type="text"
					bind:value={recommendationConfig.objectID}
					class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
				/>
			{/if}

			{#if selectedModelMetadata.requiresFacetName}
				<label
					for="recommendations-facet-name"
					class="mb-2 block text-sm font-medium text-flapjack-ink/80">Facet Name</label
				>
				<input
					id="recommendations-facet-name"
					type="text"
					bind:value={recommendationConfig.facetName}
					class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
				/>

				<label
					for="recommendations-facet-value"
					class="mb-2 block text-sm font-medium text-flapjack-ink/80">Facet Value</label
				>
				<input
					id="recommendations-facet-value"
					type="text"
					bind:value={recommendationConfig.facetValue}
					class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
				/>
			{/if}

			<label
				for="recommendations-threshold"
				class="mb-2 block text-sm font-medium text-flapjack-ink/80">Threshold</label
			>
			<input
				id="recommendations-threshold"
				type="number"
				bind:value={recommendationConfig.threshold}
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			/>

			<label
				for="recommendations-max-recommendations"
				class="mb-2 block text-sm font-medium text-flapjack-ink/80">Max Recommendations</label
			>
			<input
				id="recommendations-max-recommendations"
				type="number"
				bind:value={recommendationConfig.maxRecommendations}
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			/>

			<button
				type="submit"
				disabled={submitDisabled}
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-50"
			>
				Get Recommendations
			</button>
		</form>
	</div>

	{#if recommendationsResponse?.results?.length}
		{#if hasAnyHits(recommendationsResponse.results)}
			<div class="space-y-4">
				{#each recommendationsResponse.results as result, resultIndex (resultIndex)}
					<div class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4">
						<p class="mb-2 text-sm font-medium text-flapjack-ink">
							Request #{resultIndex + 1} · {result.processingTimeMS} ms
						</p>
						{#if result.hits.length > 0}
							<ul class="list-inside list-disc space-y-1 text-sm text-flapjack-ink/80">
								{#each result.hits as hit, hitIndex (hitIndex)}
									<li>{hitLabel(hit)}</li>
								{/each}
							</ul>
						{:else}
							<p class="text-sm text-flapjack-ink/60">No hits for this request.</p>
						{/if}
					</div>
				{/each}
			</div>
		{:else}
			<p class="text-sm text-flapjack-ink/60">No recommendations found.</p>
		{/if}
	{:else}
		<p class="text-sm text-flapjack-ink/60">No recommendations requested yet.</p>
	{/if}
</div>

<EditorDialog
	title="Edit Recommendation Configuration"
	mode="edit"
	schema={configurationEditorSchema}
	initialValue={configurationEditorInitialValue}
	open={editConfigurationDialogOpen}
	onSave={saveConfigurationEdits}
	onCancel={closeEditConfigurationDialog}
	submitLabel="Save Configuration"
	testId="recommendations-edit-dialog"
/>
