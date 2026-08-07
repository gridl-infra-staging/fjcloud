<script lang="ts">
	import type { AlgoliaIndexMetadata } from '$lib/api/types';
	import MigrationSourceIndexRow from './MigrationSourceIndexRow.svelte';

	let {
		sources,
		searchTerm = $bindable(''),
		selectedSourceName,
		nextCursor,
		isDiscovering,
		startsDisabled,
		heading = $bindable<HTMLHeadingElement | undefined>(),
		onSelect,
		onLoadMore
	}: {
		sources: AlgoliaIndexMetadata[];
		searchTerm: string;
		selectedSourceName: string | null;
		nextCursor: string | null;
		isDiscovering: boolean;
		startsDisabled: boolean;
		heading?: HTMLHeadingElement;
		onSelect: (name: string) => void;
		onLoadMore: (cursor: string) => void;
	} = $props();
</script>

<h3
	id="migration-source-title"
	bind:this={heading}
	tabindex="-1"
	class="text-base font-semibold text-flapjack-ink"
>
	Choose a source index
</h3>

<div>
	<label for="migration-source-search" class="mb-1 block text-sm font-medium">
		Search source indexes
	</label>
	<input
		id="migration-source-search"
		type="search"
		bind:value={searchTerm}
		class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
	/>
</div>

<ul data-testid="migration-source-list" class="space-y-2">
	{#each sources as source (source.name)}
		<MigrationSourceIndexRow
			{source}
			selected={selectedSourceName === source.name}
			onSelect={(name) => onSelect(name)}
		/>
	{/each}
</ul>

{#if nextCursor !== null}
	<button
		type="button"
		disabled={isDiscovering || startsDisabled}
		onclick={() => onLoadMore(nextCursor)}
		class="rounded border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium"
	>
		Load more source indexes
	</button>
{/if}
