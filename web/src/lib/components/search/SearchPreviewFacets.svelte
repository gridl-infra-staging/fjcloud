<script lang="ts">
	import FacetPanel, { type FacetPanelModel } from './FacetPanel.svelte';

	let {
		panels = [],
		onToggleFacetValue = () => {},
		onClearFacetAttribute = () => {},
		onClearAllFacets = () => {}
	}: {
		panels?: FacetPanelModel[];
		onToggleFacetValue?: (update: {
			attribute: string;
			value: string;
			nextRefined: boolean;
		}) => void;
		onClearFacetAttribute?: (attribute: string) => void;
		onClearAllFacets?: () => void;
	} = $props();
</script>

<aside class="space-y-3" data-testid="search-preview-facets">
	<div class="flex items-center justify-between">
		<h2 class="text-sm font-semibold text-flapjack-ink">Facets</h2>
		<button
			type="button"
			class="text-xs font-medium text-flapjack-rose hover:text-flapjack-plum"
			onclick={onClearAllFacets}
		>
			Clear all facets
		</button>
	</div>

	{#each panels as panel (panel.attribute)}
		<FacetPanel {panel} {onToggleFacetValue} {onClearFacetAttribute} />
	{/each}
</aside>
