<script lang="ts">
	export type FacetValue = {
		value: string;
		count: number;
		isRefined: boolean;
	};

	export type FacetPanelModel = {
		attribute: string;
		values: FacetValue[];
	};

	let {
		panel,
		onToggleFacetValue = () => {},
		onClearFacetAttribute = () => {}
	}: {
		panel: FacetPanelModel;
		onToggleFacetValue?: (update: {
			attribute: string;
			value: string;
			nextRefined: boolean;
		}) => void;
		onClearFacetAttribute?: (attribute: string) => void;
	} = $props();
</script>

<section
	class="rounded-md border border-flapjack-ink/15 p-3"
	data-testid={`facet-panel-${panel.attribute}`}
>
	<div class="mb-2 flex items-center justify-between">
		<h3 class="text-sm font-semibold text-flapjack-ink">{panel.attribute}</h3>
		{#if panel.values.some((value) => value.isRefined)}
			<button
				type="button"
				class="text-xs font-medium text-flapjack-rose hover:text-flapjack-plum"
				onclick={() => onClearFacetAttribute(panel.attribute)}
			>
				Clear {panel.attribute}
			</button>
		{/if}
	</div>

	{#if panel.values.length === 0}
		<p class="text-xs text-flapjack-ink/60">No values for these results</p>
	{:else}
		<ul class="space-y-2">
			{#each panel.values as facetValue (`${panel.attribute}:${facetValue.value}`)}
				<li
					class="flex items-center justify-between gap-2"
					data-testid={`facet-value-${panel.attribute}-${facetValue.value}`}
				>
					<label class="flex items-center gap-2 text-sm text-flapjack-ink">
						<input
							type="checkbox"
							checked={facetValue.isRefined}
							aria-label={`${panel.attribute}:${facetValue.value}`}
							onchange={(event) =>
								onToggleFacetValue({
									attribute: panel.attribute,
									value: facetValue.value,
									nextRefined: (event.currentTarget as HTMLInputElement).checked
								})}
						/>
						<span>{facetValue.value}</span>
					</label>
					<span class="text-xs text-flapjack-ink/65">{facetValue.count}</span>
				</li>
			{/each}
		</ul>
	{/if}
</section>
