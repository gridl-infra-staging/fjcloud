<script lang="ts">
	let {
		query = '',
		filterExpression = '',
		filterExpressionVisible = false,
		showFilterExpressionToggle = false,
		onQueryChange = () => {},
		onFilterExpressionVisibleChange = () => {},
		onFilterExpressionChange = () => {}
	}: {
		query?: string;
		filterExpression?: string;
		filterExpressionVisible?: boolean;
		showFilterExpressionToggle?: boolean;
		onQueryChange?: (nextQuery: string) => void;
		onFilterExpressionVisibleChange?: (visible: boolean) => void;
		onFilterExpressionChange?: (nextFilterExpression: string) => void;
	} = $props();
</script>

<section class="space-y-3" data-testid="search-preview-box">
	<label class="block text-sm font-medium text-flapjack-ink" for="search-preview-query-input">
		Search preview query
	</label>
	<input
		id="search-preview-query-input"
		type="search"
		value={query}
		aria-label="Search preview query"
		class="w-full rounded-md border border-flapjack-ink/25 px-3 py-2 text-sm"
		oninput={(event) => onQueryChange((event.currentTarget as HTMLInputElement).value)}
	/>

	{#if showFilterExpressionToggle}
		<button
			type="button"
			class="text-sm font-medium text-flapjack-rose hover:text-flapjack-plum"
			onclick={() => onFilterExpressionVisibleChange(!filterExpressionVisible)}
		>
			{filterExpressionVisible ? 'Hide filters' : 'Show filters'}
		</button>
	{/if}

	{#if filterExpression.length > 0}
		<p class="rounded bg-flapjack-cream px-2 py-1 text-xs text-flapjack-ink">
			Active filter: {filterExpression}
		</p>
	{/if}

	{#if filterExpressionVisible}
		<label class="block text-sm font-medium text-flapjack-ink" for="search-preview-filters-input">
			Search filters
		</label>
		<input
			id="search-preview-filters-input"
			type="text"
			value={filterExpression}
			aria-label="Search filters"
			class="w-full rounded-md border border-flapjack-ink/25 px-3 py-2 text-sm"
			oninput={(event) => onFilterExpressionChange((event.currentTarget as HTMLInputElement).value)}
		/>
	{/if}
</section>
