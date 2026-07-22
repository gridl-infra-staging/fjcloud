<script lang="ts">
	let {
		query = '',
		querySyncVersion = 0,
		instantSearchEnabled = false,
		filterExpression = '',
		filterExpressionVisible = false,
		showFilterExpressionToggle = false,
		onQueryChange = () => {},
		onInstantSearchEnabledChange = () => {},
		onFilterExpressionVisibleChange = () => {},
		onFilterExpressionChange = () => {}
	}: {
		query?: string;
		querySyncVersion?: number;
		instantSearchEnabled?: boolean;
		filterExpression?: string;
		filterExpressionVisible?: boolean;
		showFilterExpressionToggle?: boolean;
		onQueryChange?: (nextQuery: string) => void;
		onInstantSearchEnabledChange?: (nextEnabled: boolean) => void;
		onFilterExpressionVisibleChange?: (visible: boolean) => void;
		onFilterExpressionChange?: (nextFilterExpression: string) => void;
	} = $props();

	let draftQuery = $state('');
	let lastAppliedQuery = '';
	let lastAppliedQuerySyncVersion = -1;

	$effect(() => {
		if (query === lastAppliedQuery && querySyncVersion === lastAppliedQuerySyncVersion) {
			return;
		}
		lastAppliedQuery = query;
		lastAppliedQuerySyncVersion = querySyncVersion;
		draftQuery = query;
	});

	function submitDraftQuery(): void {
		onQueryChange(draftQuery);
	}

	function handleQueryInput(event: Event): void {
		draftQuery = (event.currentTarget as HTMLInputElement).value;
		if (instantSearchEnabled) {
			submitDraftQuery();
		}
	}

	function handleQueryKeydown(event: KeyboardEvent): void {
		if (event.key !== 'Enter') {
			return;
		}
		event.preventDefault();
		if (instantSearchEnabled) {
			return;
		}
		submitDraftQuery();
	}
</script>

<section class="space-y-3" data-testid="search-preview-box">
	<label class="inline-flex items-center gap-2 text-sm font-medium text-flapjack-ink">
		<input
			type="checkbox"
			checked={instantSearchEnabled}
			onchange={(event) =>
				onInstantSearchEnabledChange((event.currentTarget as HTMLInputElement).checked)}
		/>
		Search as you type
	</label>
	<label class="block text-sm font-medium text-flapjack-ink" for="search-preview-query-input">
		Search preview query
	</label>
	<div class="flex flex-wrap gap-2">
		<input
			id="search-preview-query-input"
			type="search"
			value={draftQuery}
			aria-label="Search preview query"
			class="min-w-0 flex-1 rounded-md border border-flapjack-ink/25 px-3 py-2 text-sm"
			oninput={handleQueryInput}
			onkeydown={handleQueryKeydown}
		/>
		<button
			type="button"
			class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
			onclick={submitDraftQuery}>Search</button
		>
	</div>

	{#if showFilterExpressionToggle}
		<button
			type="button"
			class="text-sm font-medium text-flapjack-rose hover:text-flapjack-plum"
			onclick={() => onFilterExpressionVisibleChange(!filterExpressionVisible)}
		>
			{filterExpressionVisible ? 'Hide advanced filter' : 'Add advanced filter'}
		</button>
	{/if}

	{#if filterExpression.length > 0}
		<p class="rounded bg-flapjack-cream px-2 py-1 text-xs text-flapjack-ink">
			Filtering by: {filterExpression}
		</p>
	{/if}

	{#if filterExpressionVisible}
		<label class="block text-sm font-medium text-flapjack-ink" for="search-preview-filters-input">
			Advanced filter expression
		</label>
		<p class="text-xs text-flapjack-ink/75">
			Narrow results with an expression such as <code>brand = "Acme" AND price &lt; 100</code>.
		</p>
		<input
			id="search-preview-filters-input"
			type="text"
			value={filterExpression}
			aria-label="Advanced filter expression"
			placeholder="brand = &quot;Acme&quot; AND price &lt; 100"
			class="w-full rounded-md border border-flapjack-ink/25 px-3 py-2 text-sm"
			oninput={(event) => onFilterExpressionChange((event.currentTarget as HTMLInputElement).value)}
		/>
	{/if}
</section>
