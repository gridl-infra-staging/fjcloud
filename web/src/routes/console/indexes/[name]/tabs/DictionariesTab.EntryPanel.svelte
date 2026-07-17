<script lang="ts">
	import { enhance } from '$app/forms';
	import type { DictionaryEntry, DictionaryName } from '$lib/api/types';
	import {
		buildEntryDescription,
		DICTIONARY_EMPTY_STATES,
		dictionaryEntryRowTestId
	} from '../dictionary-helpers';

	type Props = {
		activeDictionary: DictionaryName;
		activeDictionaryLabel: string;
		activeLanguage: string;
		activeQuery: string;
		activeDisplayCount: number;
		entryCount: number;
		entries: DictionaryEntry[];
		isLoading: boolean;
		dictionaryBrowseError: string;
		clearFormRef: HTMLFormElement | null;
		onRetry: () => void;
		onEditEntry: (entry: DictionaryEntry) => void;
		onDeleteEntry: (entry: DictionaryEntry, form: HTMLFormElement, trigger: HTMLElement) => void;
		onClearAll: (trigger: HTMLElement) => void;
	};

	let {
		activeDictionary,
		activeDictionaryLabel,
		activeLanguage,
		activeQuery,
		activeDisplayCount,
		entryCount,
		entries,
		isLoading,
		dictionaryBrowseError,
		clearFormRef = $bindable(null),
		onRetry,
		onEditEntry,
		onDeleteEntry,
		onClearAll
	}: Props = $props();

	const LOADING_SKELETON_KEYS = [0, 1, 2] as const;
	const activeRowTestId = $derived(dictionaryEntryRowTestId(activeDictionary));
	const hasEntries = $derived(entries.length > 0);
	const hasLoadError = $derived(dictionaryBrowseError.trim().length > 0);
</script>

<div class="rounded-lg border border-flapjack-ink/10 p-4">
	<div class="mb-4 flex items-center justify-between gap-3">
		<div class="flex items-center gap-2">
			<h3 class="text-base font-medium text-flapjack-ink">{activeDictionaryLabel}</h3>
			<span
				data-testid="dictionary-active-subheading-count"
				class="inline-flex rounded-full bg-flapjack-cream px-2.5 py-1 text-xs font-semibold text-flapjack-ink/80"
			>
				{activeDisplayCount} entries
			</span>
		</div>
	</div>

	{#if isLoading}
		<div class="space-y-3" data-testid="dictionary-loading-state">
			{#each LOADING_SKELETON_KEYS as indexAt (`skeleton-${indexAt}`)}
				<div
					data-testid="dictionary-loading-skeleton"
					class="h-16 animate-pulse rounded-md bg-flapjack-cream/80"
				></div>
			{/each}
		</div>
	{:else if hasLoadError}
		<div
			class="rounded-md border border-flapjack-rose/20 bg-flapjack-rose/10 p-4"
			data-testid="dictionary-load-error-state"
		>
			<p class="text-sm text-flapjack-plum">{dictionaryBrowseError}</p>
			<button
				type="button"
				data-testid="dictionary-retry-btn"
				class="mt-3 rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm font-medium text-flapjack-ink hover:bg-flapjack-cream"
				onclick={onRetry}
			>
				Retry
			</button>
		</div>
	{:else if !hasEntries}
		<p class="text-sm text-flapjack-ink/60">{DICTIONARY_EMPTY_STATES[activeDictionary]}</p>
	{:else}
		<div class="space-y-3" data-testid={`dictionaries-${activeDictionary}-list`}>
			{#each entries as entry (entry.objectID)}
				<div
					class="rounded-md border border-flapjack-ink/20 p-3"
					data-testid={activeRowTestId}
					data-object-id={entry.objectID}
				>
					<div class="flex flex-wrap items-start justify-between gap-3">
						<div class="min-w-0 flex-1">
							<p class="truncate text-sm font-medium text-flapjack-ink">
								{buildEntryDescription(activeDictionary, entry)}
							</p>
							<div class="mt-2 flex flex-wrap items-center gap-2">
								<span
									data-testid="badge-language"
									class="inline-flex rounded-full bg-flapjack-cream px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
								>
									{entry.language}
								</span>
								{#if activeDictionary === 'stopwords'}
									<span
										data-testid="badge-state"
										class="inline-flex rounded-full bg-flapjack-rose/10 px-2 py-0.5 text-xs font-medium text-flapjack-plum"
									>
										{entry.state === 'disabled' ? 'disabled' : 'enabled'}
									</span>
								{/if}
								<span
									class="inline-flex rounded-full bg-white px-2 py-0.5 text-xs font-medium text-flapjack-ink/70"
								>
									{entryCount} total
								</span>
							</div>
						</div>

						<div class="flex items-center gap-2">
							<button
								type="button"
								data-testid={`dictionary-entry-edit-${entry.objectID}`}
								aria-label={`Edit dictionary entry ${entry.objectID}`}
								class="rounded border border-flapjack-ink/30 px-3 py-1 text-xs text-flapjack-ink/80 hover:bg-flapjack-cream/80"
								onclick={() => onEditEntry(entry)}
							>
								Edit
							</button>
							<form method="POST" action="?/deleteDictionaryEntry" use:enhance>
								<input type="hidden" name="dictionary" value={activeDictionary} />
								<input type="hidden" name="language" value={activeLanguage} />
								<input type="hidden" name="query" value={activeQuery} />
								<input type="hidden" name="objectID" value={entry.objectID} />
								<button
									type="button"
									aria-label={`Delete dictionary entry ${entry.objectID}`}
									class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
									onclick={(event) =>
										onDeleteEntry(
											entry,
											(event.currentTarget as HTMLElement).closest('form') as HTMLFormElement,
											event.currentTarget as HTMLElement
										)}
								>
									Delete
								</button>
							</form>
						</div>
					</div>
				</div>
			{/each}
		</div>

		<div class="mt-4 flex justify-start">
			<form method="POST" action="?/clearDictionaryEntries" use:enhance bind:this={clearFormRef}>
				<input type="hidden" name="dictionary" value={activeDictionary} />
				<input type="hidden" name="language" value={activeLanguage} />
				<input type="hidden" name="query" value={activeQuery} />
				<button
					type="button"
					class="rounded-md border border-flapjack-rose/45 px-3 py-2 text-sm font-medium text-flapjack-plum hover:bg-flapjack-rose/10"
					onclick={(event) => onClearAll(event.currentTarget as HTMLElement)}
				>
					Clear All
				</button>
			</form>
		</div>
	{/if}
</div>
