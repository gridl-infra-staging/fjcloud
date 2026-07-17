<script lang="ts">
	import FacetPanel, { type FacetPanelModel } from './FacetPanel.svelte';

	let {
		panels = [],
		configurationKnown = false,
		onToggleFacetValue = () => {},
		onClearFacetAttribute = () => {},
		onClearAllFacets = () => {}
	}: {
		panels?: FacetPanelModel[];
		configurationKnown?: boolean;
		onToggleFacetValue?: (update: {
			attribute: string;
			value: string;
			nextRefined: boolean;
		}) => void;
		onClearFacetAttribute?: (attribute: string) => void;
		onClearAllFacets?: () => void;
	} = $props();

	const facetSettingsHref = '?tab=settings&settingsTab=facets-filters';
</script>

<aside class="space-y-3" data-testid="search-preview-facets">
	<div class="flex items-center justify-between">
		<h2 class="text-sm font-semibold text-flapjack-ink">Facets</h2>
		{#if panels.some((panel) => panel.values.some((value) => value.isRefined))}
			<button
				type="button"
				class="text-xs font-medium text-flapjack-rose hover:text-flapjack-plum"
				onclick={onClearAllFacets}
			>
				Clear all facets
			</button>
		{/if}
	</div>

	{#if !configurationKnown}
		<div class="text-sm text-flapjack-plum">
			<p>Couldn't load facet configuration</p>
			<!-- eslint-disable svelte/no-navigation-without-resolve -- query-only relative link preserves the raw index route -->
			<a class="mt-2 inline-block font-medium underline" href={facetSettingsHref}
				>Open facet settings</a
			>
			<!-- eslint-enable svelte/no-navigation-without-resolve -->
		</div>
	{:else if panels.length === 0}
		<div class="rounded-md border border-flapjack-ink/15 p-3 text-sm text-flapjack-ink/70">
			<p class="font-semibold text-flapjack-ink">No facets configured</p>
			<p class="mt-1">
				Make fields such as genre, year, or language filterable to refine these results.
			</p>
			<!-- eslint-disable svelte/no-navigation-without-resolve -- query-only relative link intentionally preserves the raw index route -->
			<a
				class="mt-2 inline-block font-medium text-flapjack-rose hover:text-flapjack-plum"
				href={facetSettingsHref}>Configure facets</a
			>
			<!-- eslint-enable svelte/no-navigation-without-resolve -->
		</div>
	{:else}
		{#each panels as panel (panel.attribute)}
			<FacetPanel {panel} {onToggleFacetValue} {onClearFacetAttribute} />
		{/each}
	{/if}
</aside>
