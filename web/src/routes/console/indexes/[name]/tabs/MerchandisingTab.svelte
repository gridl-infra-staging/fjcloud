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
	<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Merchandising</h2>

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
			class="flex-1 rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		/>
		<button
			type="submit"
			aria-label="Search Merchandising Results"
			class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
		>
			Search
		</button>
	</form>

	{#if merchandisingSubmittedQuery.length === 0}
		<div class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4">
			<p class="font-medium text-flapjack-ink">Enter a search query</p>
			<p class="mt-1 text-sm text-flapjack-ink/70">
				Search and then pin or hide results to create a merchandising rule.
			</p>
		</div>
	{:else}
		{#if merchandisingPins.length > 0 || merchandisingHides.length > 0}
			<div class="mb-4 rounded-md border border-flapjack-rose/30 bg-flapjack-rose/10 p-4">
				<p class="text-sm text-flapjack-ink/90">
					{merchandisingPins.length} pinned, {merchandisingHides.length} hidden
				</p>
				<div class="mt-3 flex flex-wrap items-center gap-3">
					<input
						type="text"
						bind:value={merchandisingRuleDescription}
						placeholder={`Merchandising: "${merchandisingSubmittedQuery}"`}
						class="w-full max-w-md rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
					/>
					<button
						type="button"
						aria-label="Reset Merchandising"
						onclick={resetMerchandising}
						class="rounded-md border border-flapjack-ink/30 px-3 py-1.5 text-sm text-flapjack-ink/80 hover:bg-flapjack-cream/70"
					>
						Reset
					</button>
					<button
						type="button"
						onclick={buildMerchandisingRule}
						class="rounded-md bg-flapjack-rose px-3 py-1.5 text-sm font-medium text-white hover:bg-flapjack-plum"
					>
						Save as Rule
					</button>
				</div>
			</div>
		{/if}

		{#if merchandisingPreviewResults().length === 0}
			<p class="text-sm text-flapjack-ink/60">No results</p>
		{:else}
			<div class="space-y-3">
				{#each merchandisingPreviewResults() as hit, idx (`${String(hit.objectID ?? '')}-${idx}`)}
					<div class="rounded-md border border-flapjack-ink/20 p-3">
						<div class="flex items-start justify-between gap-4">
							<div>
								<p class="font-medium text-flapjack-ink">
									{String(hit.name ?? hit.objectID ?? '')}
								</p>
								<p class="text-xs text-flapjack-ink/60">{String(hit.objectID ?? '')}</p>
							</div>
							<div class="flex items-center gap-2">
								{#if isPinned(String(hit.objectID ?? ''))}
									<span
										class="inline-flex rounded-full bg-flapjack-rose/10 px-2 py-0.5 text-xs font-medium text-flapjack-plum"
										>#{idx + 1}</span
									>
								{/if}
								<button
									type="button"
									aria-label={`Pin ${String(hit.objectID ?? '')}`}
									onclick={() => togglePin(String(hit.objectID ?? ''), idx)}
									class="rounded border border-flapjack-rose/40 px-2 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
								>
									Pin
								</button>
								<button
									type="button"
									aria-label={`Hide ${String(hit.objectID ?? '')}`}
									onclick={() => toggleHide(String(hit.objectID ?? ''))}
									class="rounded border border-flapjack-rose/45 px-2 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
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
			<div class="mt-6 rounded-md border border-flapjack-ink/20 p-4">
				<h3 class="mb-2 text-sm font-semibold text-flapjack-ink">Hidden results</h3>
				<div class="space-y-2 text-sm text-flapjack-ink/80">
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
				class="mt-4 rounded-md border border-flapjack-ink/20 p-4"
			>
				<input type="hidden" name="objectID" value={merchandisingRule.objectID} />
				<input type="hidden" name="rule" value={JSON.stringify(merchandisingRule)} />
				<button
					type="submit"
					class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
				>
					Confirm Save Rule
				</button>
			</form>
		{/if}
	{/if}
</div>
