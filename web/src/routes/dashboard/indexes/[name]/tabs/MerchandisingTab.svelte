<script lang="ts">
	import { enhance } from '$app/forms';
	import { createMerchandisingRule } from '$lib/utils/merchandising';
	import type { Index, Rule, SearchResult } from '$lib/api/types';

	type Props = {
		index: Index;
		searchResult: SearchResult | null;
		searchQuery: string;
	};

	let { index, searchResult, searchQuery }: Props = $props();

	let merchandisingQuery = $state('');
	let merchandisingSubmittedQuery = $state('');
	let merchandisingPins = $state<Array<{ objectID: string; position: number }>>([]);
	let merchandisingHides = $state<Array<{ objectID: string }>>([]);
	let merchandisingRuleDescription = $state('');
	let merchandisingRule: Rule | null = $state(null);

	function merchandisingSourceHits(): Array<Record<string, unknown>> {
		if (
			!merchandisingSubmittedQuery ||
			!searchResult ||
			searchQuery !== merchandisingSubmittedQuery
		) {
			return [];
		}
		return (searchResult.hits as Array<Record<string, unknown>>) ?? [];
	}

	function merchandisingPreviewResults(): Array<Record<string, unknown>> {
		const sourceHits = merchandisingSourceHits();
		if (sourceHits.length === 0) return [];

		const hidden = new Set(merchandisingHides.map((entry) => entry.objectID));
		const pinned = new Set(merchandisingPins.map((entry) => entry.objectID));

		const visible = sourceHits.filter((hit) => {
			const objectID = String(hit.objectID ?? '');
			return objectID.length > 0 && !hidden.has(objectID) && !pinned.has(objectID);
		});

		const result = [...visible];
		const sortedPins = [...merchandisingPins].sort((a, b) => a.position - b.position);
		for (const pin of sortedPins) {
			const hit = sourceHits.find((candidate) => String(candidate.objectID ?? '') === pin.objectID);
			if (!hit) continue;
			result.splice(Math.min(pin.position, result.length), 0, hit);
		}

		return result;
	}

	function isPinned(objectID: string): boolean {
		return merchandisingPins.some((entry) => entry.objectID === objectID);
	}

	function isHidden(objectID: string): boolean {
		return merchandisingHides.some((entry) => entry.objectID === objectID);
	}

	function submitMerchandisingQuery() {
		merchandisingSubmittedQuery = merchandisingQuery.trim();
		merchandisingPins = [];
		merchandisingHides = [];
		merchandisingRuleDescription = '';
		merchandisingRule = null;
	}

	function togglePin(objectID: string, position: number) {
		merchandisingRule = null;
		if (isPinned(objectID)) {
			merchandisingPins = merchandisingPins.filter((entry) => entry.objectID !== objectID);
			return;
		}

		merchandisingPins = [...merchandisingPins, { objectID, position }];
		merchandisingHides = merchandisingHides.filter((entry) => entry.objectID !== objectID);
	}

	function toggleHide(objectID: string) {
		merchandisingRule = null;
		if (isHidden(objectID)) {
			merchandisingHides = merchandisingHides.filter((entry) => entry.objectID !== objectID);
			return;
		}

		merchandisingHides = [...merchandisingHides, { objectID }];
		merchandisingPins = merchandisingPins.filter((entry) => entry.objectID !== objectID);
	}

	function resetMerchandising() {
		merchandisingPins = [];
		merchandisingHides = [];
		merchandisingRuleDescription = '';
		merchandisingRule = null;
	}

	function buildMerchandisingRule() {
		if (!merchandisingSubmittedQuery) return;
		merchandisingRule = createMerchandisingRule({
			query: merchandisingSubmittedQuery,
			description: merchandisingRuleDescription,
			pins: merchandisingPins,
			hides: merchandisingHides
		});
	}
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid="merchandising-section"
	data-index={index.name}
>
	<h2 class="mb-4 text-lg font-medium text-gray-900">Merchandising</h2>

	<form
		method="POST"
		action="?/search"
		use:enhance
		class="mb-4 flex gap-3"
		onsubmit={submitMerchandisingQuery}
	>
		<input
			type="text"
			name="query"
			bind:value={merchandisingQuery}
			placeholder="Enter a search query"
			class="flex-1 rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
		/>
		<button
			type="submit"
			aria-label="Search Merchandising Results"
			class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
		>
			Search
		</button>
	</form>

	{#if merchandisingSubmittedQuery.length === 0}
		<div class="rounded-md border border-gray-200 bg-gray-50 p-4">
			<p class="font-medium text-gray-900">Enter a search query</p>
			<p class="mt-1 text-sm text-gray-600">
				Search and then pin or hide results to create a merchandising rule.
			</p>
		</div>
	{:else}
		{#if merchandisingPins.length > 0 || merchandisingHides.length > 0}
			<div class="mb-4 rounded-md border border-blue-200 bg-blue-50 p-4">
				<p class="text-sm text-blue-900">
					{merchandisingPins.length} pinned, {merchandisingHides.length} hidden
				</p>
				<div class="mt-3 flex flex-wrap items-center gap-3">
					<input
						type="text"
						bind:value={merchandisingRuleDescription}
						placeholder={`Merchandising: "${merchandisingSubmittedQuery}"`}
						class="w-full max-w-md rounded-md border border-gray-300 px-3 py-2 text-sm"
					/>
					<button
						type="button"
						aria-label="Reset Merchandising"
						onclick={resetMerchandising}
						class="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-100"
					>
						Reset
					</button>
					<button
						type="button"
						onclick={buildMerchandisingRule}
						class="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700"
					>
						Save as Rule
					</button>
				</div>
			</div>
		{/if}

		{#if merchandisingPreviewResults().length === 0}
			<p class="text-sm text-gray-500">No results</p>
		{:else}
			<div class="space-y-3">
				{#each merchandisingPreviewResults() as hit, idx (`${String(hit.objectID ?? '')}-${idx}`)}
					<div class="rounded-md border border-gray-200 p-3">
						<div class="flex items-start justify-between gap-4">
							<div>
								<p class="font-medium text-gray-900">{String(hit.name ?? hit.objectID ?? '')}</p>
								<p class="text-xs text-gray-500">{String(hit.objectID ?? '')}</p>
							</div>
							<div class="flex items-center gap-2">
								{#if isPinned(String(hit.objectID ?? ''))}
									<span
										class="inline-flex rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-800"
										>#{idx + 1}</span
									>
								{/if}
								<button
									type="button"
									aria-label={`Pin ${String(hit.objectID ?? '')}`}
									onclick={() => togglePin(String(hit.objectID ?? ''), idx)}
									class="rounded border border-blue-300 px-2 py-1 text-xs text-blue-700 hover:bg-blue-50"
								>
									Pin
								</button>
								<button
									type="button"
									aria-label={`Hide ${String(hit.objectID ?? '')}`}
									onclick={() => toggleHide(String(hit.objectID ?? ''))}
									class="rounded border border-red-300 px-2 py-1 text-xs text-red-700 hover:bg-red-50"
								>
									Hide
								</button>
							</div>
						</div>
					</div>
				{/each}
			</div>
		{/if}

		{#if merchandisingHides.length > 0}
			<div class="mt-6 rounded-md border border-gray-200 p-4">
				<h3 class="mb-2 text-sm font-semibold text-gray-900">Hidden results</h3>
				<div class="space-y-2 text-sm text-gray-700">
					{#each merchandisingHides as hidden (hidden.objectID)}
						{@const hiddenHit = merchandisingSourceHits().find(
							(hit) => String(hit.objectID ?? '') === hidden.objectID
						)}
						<p>{String(hiddenHit?.name ?? hidden.objectID)}</p>
					{/each}
				</div>
			</div>
		{/if}

		{#if merchandisingRule}
			<form
				method="POST"
				action="?/saveRule"
				use:enhance
				class="mt-4 rounded-md border border-gray-200 p-4"
			>
				<input type="hidden" name="objectID" value={merchandisingRule.objectID} />
				<input type="hidden" name="rule" value={JSON.stringify(merchandisingRule)} />
				<button
					type="submit"
					class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
				>
					Confirm Save Rule
				</button>
			</form>
		{/if}
	{/if}
</div>
