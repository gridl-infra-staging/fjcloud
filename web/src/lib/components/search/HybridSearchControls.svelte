<script lang="ts">
	type SearchCapabilities = {
		vectorSearch: boolean;
	};

	let {
		capabilities,
		embedderCount,
		enabled = false,
		onHybridEnabledChange = () => {}
	}: {
		capabilities: SearchCapabilities;
		embedderCount: number;
		enabled?: boolean;
		onHybridEnabledChange?: (nextEnabled: boolean) => void;
	} = $props();

	const visible = $derived(capabilities.vectorSearch === true && embedderCount > 0);
</script>

{#if visible}
	<section
		class="rounded-md border border-flapjack-ink/15 p-3"
		data-testid="hybrid-search-controls"
	>
		<label class="inline-flex items-center gap-2 text-sm text-flapjack-ink">
			<input
				type="checkbox"
				checked={enabled}
				aria-label="Enable hybrid search"
				onchange={(event) =>
					onHybridEnabledChange((event.currentTarget as HTMLInputElement).checked)}
			/>
			Enable hybrid search
		</label>
	</section>
{/if}
