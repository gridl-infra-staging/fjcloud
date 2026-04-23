<script lang="ts">
	import { browser } from '$app/environment';
	import { onDestroy } from 'svelte';
	import { createFlapjackInstantSearchClient } from '$lib/flapjack-search-client';

	type SearchHit = {
		objectID?: string;
		title?: string;
		body?: string;
		[key: string]: unknown;
	};

	type SearchResult = {
		hits?: SearchHit[];
		nbHits?: number;
	};

	let { endpoint, apiKey, indexName }: { endpoint: string; apiKey: string; indexName: string } =
		$props();

	let query = $state('');
	let hits = $state<SearchHit[]>([]);
	let nbHits = $state(0);
	let loading = $state(false);
	let searchSubmitted = $state(false);
	let searchError = $state('');

	const client = $derived(createFlapjackInstantSearchClient(endpoint, apiKey));

	let activeRequest = 0;

	function buildSearchParams(nextQuery: string): string {
		const params = new URLSearchParams();
		params.set('query', nextQuery);
		return params.toString();
	}

	function formatHitDetails(hit: SearchHit): string | null {
		const { objectID, title, body, ...rest } = hit;
		void objectID;
		void title;
		void body;

		if (Object.keys(rest).length === 0) {
			return null;
		}

		return JSON.stringify(rest, null, 2);
	}

	async function runSearch(nextQuery: string): Promise<void> {
		if (!browser) return;

		searchSubmitted = true;
		searchError = '';
		loading = true;

		const requestId = ++activeRequest;

		try {
			const response = await client.search([
				{
					indexName,
					params: buildSearchParams(nextQuery)
				}
			]);

			if (requestId !== activeRequest) {
				return;
			}

			const result = (response.results[0] ?? {}) as SearchResult;
			hits = Array.isArray(result.hits) ? result.hits : [];
			nbHits = typeof result.nbHits === 'number' ? result.nbHits : hits.length;
		} catch (error) {
			if (requestId !== activeRequest) {
				return;
			}

			hits = [];
			nbHits = 0;
			searchError = error instanceof Error ? error.message : 'Search failed';
		} finally {
			if (requestId === activeRequest) {
				loading = false;
			}
		}
	}

	async function handleSubmit(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		await runSearch(query);
	}

	onDestroy(() => {
		activeRequest += 1;
	});
</script>

<div data-testid="instantsearch-widget" class="space-y-4">
	<div data-testid="instantsearch-searchbox">
		<form class="ais-SearchBox-form" role="search" onsubmit={handleSubmit}>
			<input
				bind:value={query}
				class="ais-SearchBox-input"
				type="search"
				placeholder="Search your index..."
				aria-label="Search"
			/>
			<button class="ais-SearchBox-submit" type="submit" aria-label="Submit the search query">
				Search
			</button>
			<button class="ais-SearchBox-reset" type="button" aria-hidden="true" tabindex="-1">
				Reset
			</button>
		</form>
	</div>

	<div class="text-sm text-gray-500">
		{#if loading}
			Searching...
		{:else if searchError}
			{searchError}
		{:else if searchSubmitted}
			{nbHits} {nbHits === 1 ? 'result' : 'results'}
		{/if}
	</div>

	<div data-testid="instantsearch-hits">
		{#if loading}
			<p class="text-gray-500">Searching...</p>
		{:else if searchError}
			<p class="text-red-600">{searchError}</p>
		{:else if searchSubmitted && hits.length === 0}
			<p class="text-gray-500">No results found.</p>
		{:else}
			{#each hits as hit}
				<article class="hit-item">
					<strong>{hit.title ?? hit.objectID ?? 'Untitled result'}</strong>
					{#if hit.body}
						<p class="mt-2 text-sm text-gray-600">{hit.body}</p>
					{/if}
					{#if formatHitDetails(hit)}
						<pre>{formatHitDetails(hit)}</pre>
					{/if}
				</article>
			{/each}
		{/if}
	</div>
</div>

<style>
	:global(.ais-SearchBox-form) {
		display: flex;
		gap: 0.5rem;
	}

	:global(.ais-SearchBox-input) {
		flex: 1;
		padding: 0.5rem 0.75rem;
		border: 1px solid #d1d5db;
		border-radius: 0.375rem;
		font-size: 0.875rem;
	}

	:global(.ais-SearchBox-submit) {
		padding: 0.5rem 1rem;
		background-color: #2563eb;
		color: white;
		border: none;
		border-radius: 0.375rem;
		cursor: pointer;
	}

	:global(.ais-SearchBox-reset) {
		display: none;
	}

	:global(.hit-item) {
		padding: 0.75rem;
		border: 1px solid #e5e7eb;
		border-radius: 0.375rem;
		margin-bottom: 0.5rem;
	}

	:global(.hit-item pre) {
		font-size: 0.75rem;
		color: #6b7280;
		white-space: pre-wrap;
		word-break: break-all;
		margin-top: 0.25rem;
	}
 </style>
